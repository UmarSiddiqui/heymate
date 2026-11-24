import CryptoKit
import SwiftUI
import UIKit
import VisionKit

@main
struct PhonePilotApp: App {
    @StateObject private var account = HeyMateAccount()
    @StateObject private var pilot = PhonePilotModel()

    var body: some Scene {
        WindowGroup {
            PhonePilotHome(account: account, pilot: pilot)
                .task {
                    pilot.bind(account)
                    await account.restore()
                }
                .task(id: account.session?.uid) { pilot.load(uid: account.session?.uid) }
        }
    }
}

@MainActor
final class PhonePilotModel: ObservableObject {
    struct LocalAttachment: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    struct Pending: Codable {
        let id: UUID
        let envelope: Data
        let expiration: Date?
        var submitted = false
        var kind: PhonePilotRequest.Kind?
        var mateID: UUID?
        var title: String?
        var catalogAfter: UUID?
        var quietly: Bool?
        var chatID: UUID?
    }

    struct Activity: Codable, Identifiable {
        let id: UUID
        let name: String
        let title: String
        let reply: String
        let time: Date
        let failed: Bool
    }

    struct Connection: Codable {
        let channel: PhonePilotChannel
        var mateName: String?
        var pending: Pending?
        var lastReport: String?
        var cleanupTask: UUID?
        var mates: [PhonePilotMate]?
        var activity: [Activity]?
        var themeHex: String?
    }

    @Published private(set) var connection: Connection?
    @Published private(set) var status: String?
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    @Published private(set) var uploading = false
    @Published private(set) var workspace: PhoneWorkspace?
    @Published private(set) var chats: [UUID: [PhoneChat]] = [:]
    @Published private(set) var threads: [UUID: PhoneThread] = [:]
    @Published private(set) var routines: [PhoneRoutine]?
    @Published private(set) var profiles: [UUID: PhoneMateProfile] = [:]
    @Published private(set) var openedChat: PhoneChat?
    @Published private(set) var notice: String?
    @Published private(set) var stoppingTurnID: UUID?
    @Published var companionLink: PhoneCompanionLink?

    private var nextMateID: UUID?
    private weak var account: HeyMateAccount?
    private var submittingChat = false
    private var lastStoppedTurnID: UUID?
    private let store = PhonePilotKeychain<Connection>(account: "iphone")
    private let mailbox = FirebaseAccountConfiguration.bundled.map { PhonePilotMailbox(projectID: $0.projectID) }

    func bind(_ account: HeyMateAccount) { self.account = account }

    func load(uid: String?) {
        connection = nil
        status = nil
        problem = nil
        workspace = nil
        nextMateID = nil
        chats = [:]
        threads = [:]
        routines = nil
        profiles = [:]
        openedChat = nil
        notice = nil
        stoppingTurnID = nil
        lastStoppedTurnID = nil
        guard let uid else { return }
        do {
            if let saved = try store.load(), saved.channel.uid == uid { connection = saved }
        } catch { problem = PhonePilotError.secureStorage.localizedDescription }
    }

    func pair(code: String, uid: String) {
        guard connection == nil else { return }
        do {
            let invite = try PhonePilotInvite.decode(code, uid: uid)
            let phoneKey = Curve25519.KeyAgreement.PrivateKey()
            let trafficKey = try invite.key(privateKey: phoneKey, peer: invite.publicKey)
            let id = UUID()
            let offer = PhonePilotChannel(uid: uid, pairID: invite.pairID, key: invite.secret)
            let message = PhonePilotRequest(kind: .pair, phonePublicKey: phoneKey.publicKey.rawRepresentation)
            let envelope = try offer.seal(message, taskID: id, direction: .pairingRequest)
            try save(.init(channel: .init(uid: uid, pairID: invite.pairID, key: trafficKey),
                           pending: .init(id: id, envelope: envelope, expiration: invite.expiresAt)))
            problem = nil
        } catch { problem = (error as? PhonePilotError)?.localizedDescription ?? PhonePilotError.invalidInvite.localizedDescription }
    }

    func checkMail(mateID: UUID? = nil) {
        enqueue(.init(kind: .unreadMail, mateID: mateID), title: "Check unread mail")
    }

    func loadMates() { enqueue(.init(kind: .workspace), title: "Refresh workspace") }

    func send(_ text: String, mateID: UUID, chatID: UUID? = nil) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= PhonePilotRequest.messageLimit else { return }
        enqueue(.init(kind: .message, mateID: mateID, message: message, chatID: chatID), title: message)
    }

    func sendChat(_ text: String, chat: PhoneChat, startsNewChat: Bool,
                  brain: PhoneBrainChoice?, files: [LocalAttachment]) async -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!typed.isEmpty || !files.isEmpty), typed.count <= PhonePilotRequest.messageLimit else { return false }
        let body = typed.isEmpty ? "Here are some files." : typed
        var request = PhonePilotRequest(kind: .message, mateID: chat.mateID, message: body, chatID: chat.id,
                                        startsNewChat: startsNewChat, followsTranscript: true, brain: brain)
        guard !uploading, watchID == nil, let channel = connection?.channel else { return false }
        let lease = workspace?.supportsActivityPush == true ? PhoneChatSendLease() : nil
        defer { lease?.end() }
        if files.isEmpty {
            uploading = true
            return await enqueueChat(request, title: body, chat: chat, channel: channel)
        }
        guard let mailbox, let account else { return false }
        let manifest = files.map { file in
            let count = (file.data.count + PhoneAttachment.chunkSize - 1) / PhoneAttachment.chunkSize
            return PhoneAttachment(name: file.name, size: file.data.count, chunks: (0..<count).map { _ in UUID() })
        }
        guard PhoneAttachment.validate(manifest) else { return false }
        uploading = true
        status = "Uploading attachments…"
        problem = nil
        var attempted: [UUID] = []
        var token: String?
        do {
            let auth = try await account.phonePilotSession()
            guard auth.uid == channel.uid else { throw PhonePilotError.unavailable }
            token = auth.idToken
            for (file, metadata) in zip(files, manifest) {
                for start in stride(from: 0, to: metadata.chunks.count, by: PhoneAttachment.uploadBatchSize) {
                    try Task.checkCancellation()
                    guard channel == connection?.channel else { throw PhonePilotError.unavailable }
                    let stop = min(start + PhoneAttachment.uploadBatchSize, metadata.chunks.count)
                    let batch = try (start..<stop).map { index -> (UUID, Data) in
                        let offset = index * PhoneAttachment.chunkSize
                        let end = min(offset + PhoneAttachment.chunkSize, file.data.count)
                        let bytes = file.data.subdata(in: offset..<end)
                        let id = metadata.chunks[index]
                        return (id, try channel.seal(bytes, taskID: id, direction: .attachment))
                    }
                    attempted += batch.map { $0.0 }
                    try await mailbox.uploadAttachments(batch, channel: channel, token: auth.idToken)
                }
            }
            guard channel == connection?.channel else { throw PhonePilotError.unavailable }
            request.attachments = manifest
            if await enqueueChat(request, title: body, chat: chat, channel: channel) { return true }
        } catch { problem = "Couldn’t upload the attachments. Check your connection and try again." }
        if let token { try? await mailbox.deleteAttachments(attempted, channel: channel, token: token) }
        uploading = false
        status = nil
        return false
    }

    private func enqueueChat(_ request: PhonePilotRequest, title: String, chat: PhoneChat,
                             channel: PhonePilotChannel) async -> Bool {
        let remoteUpdates = workspace?.supportsActivityPush == true
        let activity = PhoneLiveActivity.start(chat, remoteUpdates: remoteUpdates)
        var outgoing = request
        if remoteUpdates { outgoing.activityPush = await PhoneLiveActivity.pushTarget(for: activity) }
        uploading = false
        // A supported activity should keep tracking if the phone locks just after Send.
        // Claim the initial mailbox write here so the scene's polling task can suspend.
        submittingChat = outgoing.activityPush != nil
        defer { submittingChat = false }
        guard !Task.isCancelled, channel == connection?.channel,
              enqueue(outgoing, title: title) else {
            PhoneLiveActivity.discard(activity)
            return false
        }
        if submittingChat { await submitActivityMessage(channel: channel) }
        return true
    }

    private func submitActivityMessage(channel: PhonePilotChannel) async {
        guard let account, let mailbox, var pair = connection, var pending = pair.pending else { return }
        do {
            let auth = try await account.phonePilotSession()
            guard auth.uid == channel.uid, pair.channel == channel, isCurrent(pair, task: pending.id) else { return }
            do {
                try await mailbox.enqueue(channel, id: pending.id, envelope: pending.envelope, token: auth.idToken)
            } catch PhonePilotError.conflict { /* The same request already reached the mailbox. */ }
            guard isCurrent(pair, task: pending.id) else { return }
            pending.submitted = true
            pair.pending = pending
            try save(pair)
            status = "Queued · waiting for your Mac"
        } catch {
            // The encrypted pending request remains available for the normal retry path.
        }
    }

    var visibleChatID: UUID?

    func refreshLiveChatIfNeeded() {
        guard workspace?.sharing == true, watchID == nil,
              let target = PhoneLiveActivity.current?.attributes, target.chatID != visibleChatID,
              connection?.mates?.contains(where: { $0.id == target.mateID }) == true else { return }
        enqueue(.init(kind: .transcript, mateID: target.mateID, chatID: target.chatID), title: "Load chat", quietly: true)
    }

    @discardableResult
    func enqueue(_ request: PhonePilotRequest, title: String, quietly: Bool = false) -> Bool {
        guard !uploading, var pair = connection, pair.mateName != nil, pair.pending == nil, pair.cleanupTask == nil else { return false }
        do {
            let id = UUID()
            let envelope = try pair.channel.seal(request, taskID: id, direction: .request)
            guard envelope.count <= 8192 else { problem = "That request is too long. Shorten it and try again."; return false }
            pair.pending = .init(id: id, envelope: envelope, expiration: nil, kind: request.kind, mateID: request.mateID, title: title,
                                 catalogAfter: request.kind == .mates ? request.before : nil, quietly: quietly, chatID: request.chatID)
            try save(pair)
            if !quietly {
                status = "Sending to your Mac…"
                problem = nil
                notice = nil
            }
            return true
        } catch { problem = PhonePilotError.secureStorage.localizedDescription; return false }
    }

    func stopReply(_ chat: PhoneChat) async {
        guard workspace?.supportsStopReply == true, let turnID = chat.turnID,
              stoppingTurnID == nil, let channel = connection?.channel, let account, let mailbox else { return }
        let request = PhonePilotRequest(kind: .stopReply, mateID: chat.mateID, chatID: chat.id, itemID: turnID)
        let taskID = UUID()
        let lease = PhoneChatSendLease()
        stoppingTurnID = turnID
        notice = nil
        defer {
            lease.end()
            if stoppingTurnID == turnID { stoppingTurnID = nil }
        }
        do {
            if account.busy { try await Task.sleep(for: .milliseconds(800)) }
            let auth = try await account.phonePilotSession()
            guard auth.uid == channel.uid, connection?.channel == channel else { return }
            let envelope = try channel.seal(request, taskID: taskID, direction: .request)
            do { try await mailbox.enqueue(channel, id: taskID, envelope: envelope, token: auth.idToken) }
            catch PhonePilotError.conflict { /* Retry can observe the existing stop request. */ }
            let deadline = Date.now.addingTimeInterval(24)
            repeat {
                try Task.checkCancellation()
                guard connection?.channel == channel else { return }
                if let task = try await mailbox.task(channel, id: taskID, token: auth.idToken),
                   let result = task.result, task.status == "completed" || task.status == "failed" {
                    let reply = try channel.open(PhonePilotReply.self, data: result, taskID: taskID, direction: .result)
                    guard connection?.channel == channel else { return }
                    if task.status == "completed" {
                        lastStoppedTurnID = turnID
                        PhoneLiveActivity.update(chatID: chat.id, stage: .stopped)
                    }
                    let pending = Pending(id: taskID, envelope: envelope, expiration: nil, kind: .stopReply,
                                          mateID: chat.mateID, chatID: chat.id)
                    apply(reply, pending: pending, failed: task.status == "failed")
                    notice = reply.text
                    try? await mailbox.delete(channel, task: task, token: auth.idToken)
                    return
                }
                try await Task.sleep(for: .seconds(1))
            } while Date.now < deadline
            notice = "Stop requested. Waiting for your Mac."
        } catch is CancellationError { }
        catch {
            if connection?.channel == channel { notice = "Couldn’t confirm Stop Reply. Check your Mac connection." }
        }
    }

    func disconnect() {
        do {
            try store.clear()
            PhoneLiveActivity.clear()
            companionLink = nil
            load(uid: nil)
        } catch { problem = PhonePilotError.secureStorage.localizedDescription }
    }

    func refresh(using account: HeyMateAccount) async {
        guard !submittingChat, !busy, !account.busy, account.mayUseApp, var current = connection, let mailbox,
              let requestedTask = current.pending?.id ?? current.cleanupTask else { return }
        busy = true
        defer { busy = false }
        do {
            let auth = try await account.phonePilotSession()
            guard auth.uid == current.channel.uid, isCurrent(current, task: requestedTask) else { return }
            if let cleanup = current.cleanupTask {
                if let old = try await mailbox.task(current.channel, id: cleanup, token: auth.idToken) {
                    try await mailbox.delete(current.channel, task: old, token: auth.idToken)
                }
                guard isCurrent(current, task: requestedTask) else { return }
                current.cleanupTask = nil
                try save(current)
                problem = nil
                return
            }
            guard var pending = current.pending else { return }
            let existing = try await mailbox.task(current.channel, id: pending.id, token: auth.idToken)
            guard isCurrent(current, task: requestedTask) else { return }
            if let task = existing {
                if let bytes = task.result, task.status == "completed" || task.status == "failed" {
                    let reply = try current.channel.open(PhonePilotReply.self, data: bytes, taskID: task.id, direction: .result)
                    if let mates = reply.mates {
                        if pending.catalogAfter != nil {
                            let existingIDs = Set((current.mates ?? []).map(\.id))
                            current.mates = (current.mates ?? []) + mates.filter { !existingIDs.contains($0.id) }
                        } else { current.mates = mates }
                        nextMateID = reply.nextMateID
                    }
                    if let workspace = reply.workspace { current.themeHex = workspace.theme }
                    apply(reply, pending: pending, failed: task.status == "failed")
                    if pending.expiration != nil {
                        guard task.status == "completed", let name = reply.mateName, !name.isEmpty else {
                            throw PhonePilotError.invalidResponse
                        }
                        current.mateName = name
                    } else if pending.kind == .message || pending.kind == .unreadMail || pending.kind == nil {
                        current.lastReport = reply.text
                        let name = current.mates?.first { $0.id == pending.mateID }?.name ?? "HeyMate"
                        let entry = Activity(id: task.id, name: name, title: pending.title ?? "Check unread mail",
                            reply: reply.text, time: .now, failed: task.status == "failed")
                        current.activity = Array(([entry] + (current.activity ?? [])).prefix(24))
                    }
                    current.pending = nil
                    current.cleanupTask = task.id
                    try save(current)
                    status = nil
                } else {
                    if let expiration = pending.expiration, expiration < .now, task.status == "queued" {
                        try await mailbox.delete(current.channel, task: task, token: auth.idToken)
                        guard isCurrent(current, task: requestedTask) else { return }
                        disconnect()
                        throw PhonePilotError.invalidInvite
                    }
                    if task.status == "running", pending.kind == .message, let chatID = pending.chatID {
                        PhoneLiveActivity.update(chatID: chatID, stage: .working)
                    }
                    if pending.quietly != true {
                        status = task.status == "running" ? "Working on your Mac…" : "Queued · waiting for your Mac"
                    }
                }
            } else if !pending.submitted {
                if let expiration = pending.expiration, expiration <= .now {
                    disconnect()
                    throw PhonePilotError.invalidInvite
                }
                do {
                    try await mailbox.enqueue(current.channel, id: pending.id, envelope: pending.envelope, token: auth.idToken)
                } catch PhonePilotError.conflict { /* The prior request may have reached Firestore. */ }
                guard isCurrent(current, task: requestedTask) else { return }
                pending.submitted = true
                current.pending = pending
                try save(current)
                if pending.quietly != true { status = "Queued · waiting for your Mac" }
            } else {
                if pending.expiration != nil { disconnect() }
                else {
                    current.pending = nil
                    try save(current)
                }
                throw PhonePilotError.invalidResponse
            }
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                problem = (error as? PhonePilotError)?.localizedDescription ??
                    (error as? FirebaseAccountError)?.localizedDescription ?? PhonePilotError.unavailable.localizedDescription
            }
        }
    }

    func loadNextMatePage() -> Bool {
        guard let nextMateID,
              enqueue(.init(kind: .mates, before: nextMateID), title: "Sync mates") else { return false }
        self.nextMateID = nil
        return true
    }

    var watchID: UUID? { connection?.pending?.id ?? connection?.cleanupTask }

    private func apply(_ reply: PhonePilotReply, pending: Pending, failed: Bool) {
        if let workspace = reply.workspace {
            self.workspace = workspace
            if !workspace.sharing { chats = [:]; threads = [:]; routines = nil; profiles = [:] }
        }
        if let list = reply.chats, let mateID = pending.mateID { chats[mateID] = list }
        if let routines = reply.routines { self.routines = routines }
        if let profile = reply.profile, let mateID = pending.mateID { profiles[mateID] = profile }
        if var thread = reply.thread, thread.chat.turnID == nil || thread.chat.turnID != lastStoppedTurnID {
            let id = thread.chat.id
            if let previous = threads[id] {
                let received = Set(thread.messages.map(\.id))
                let older = previous.messages.filter { !received.contains($0.id) }
                thread.messages = thread.appendsOlder ? thread.messages + older : older + thread.messages
                thread.messages.sort { $0.time < $1.time }
                if !thread.appendsOlder, !previous.older { thread.older = false }
            }
            threads[id] = thread
            var list = chats[thread.chat.mateID] ?? []
            list.removeAll { $0.id == id }
            list.insert(thread.chat, at: 0)
            chats[thread.chat.mateID] = list
            if pending.kind == .newChat { openedChat = thread.chat }
            if !thread.appendsOlder, pending.kind != .stopReply {
                if failed { PhoneLiveActivity.update(chatID: id, stage: .failed) }
                else if thread.chat.busy { PhoneLiveActivity.update(chatID: id, stage: .working) }
                else {
                    PhoneLiveActivity.update(chatID: id, stage: thread.messages.last?.user == false ? .ready : .failed)
                }
            }
        } else if failed, let chatID = pending.chatID, pending.kind == .message || pending.kind == .transcript {
            PhoneLiveActivity.update(chatID: chatID, stage: .failed)
        }
        if (failed && pending.quietly != true) || [.continueOnMac, .saveProfile, .createMate, .saveRoutine, .routineAction, .answer].contains(pending.kind) {
            notice = reply.text
        }
    }

    private func isCurrent(_ current: Connection, task: UUID) -> Bool {
        !Task.isCancelled && connection?.channel == current.channel && watchID == task
    }

    private func save(_ value: Connection) throws {
        try store.save(value)
        connection = value
    }
}

@MainActor
private final class PhoneChatSendLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Send HeyMate chat") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct PhonePilotHome: View {
    private struct WatchKey: Equatable {
        let taskID: UUID?
        let active: Bool
        let signedIn: Bool
    }

    @ObservedObject var account: HeyMateAccount
    @ObservedObject var pilot: PhonePilotModel
    @Environment(\.scenePhase) private var phase
    @State private var code = ""
    @State private var scanner = false
    @State private var didRequestWorkspace = false

    var body: some View {
        Group {
            if account.mayUseApp, pilot.connection?.mateName != nil {
                PhoneWorkspaceHome(pilot: pilot) {
                    if account.signOut() { pilot.disconnect(); didRequestWorkspace = false }
                }
            } else {
                onboarding
            }
        }
        .foregroundStyle(HeyMatePalette.primary)
        .tint(HeyMatePalette.accent(pilot.connection?.themeHex))
        .environment(\.phoneAccentHex, pilot.connection?.themeHex)
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            if let link = PhoneCompanionLink(url: url) { pilot.companionLink = link }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                if account.mayUseApp { pilot.refreshLiveChatIfNeeded() }
            }
        }
        .sheet(isPresented: $scanner) {
            PairScanner { scanned in scanner = false; pair(scanned) }
                .ignoresSafeArea()
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { didRequestWorkspace = false }
        }
        .task(id: WatchKey(taskID: pilot.watchID, active: phase == .active, signedIn: account.mayUseApp)) {
            guard phase == .active, account.mayUseApp else { return }
            var attempts = 0
            while !Task.isCancelled, pilot.watchID != nil {
                await pilot.refresh(using: account)
                attempts += 1
                do { try await Task.sleep(for: .seconds(attempts < 10 ? 2 : 8)) }
                catch { return }
            }
            guard !Task.isCancelled, pilot.connection?.mateName != nil else { return }
            if pilot.loadNextMatePage() { return }
            if !didRequestWorkspace {
                didRequestWorkspace = pilot.enqueue(.init(kind: .workspace), title: "Refresh workspace")
            }
        }
    }

    private var onboarding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("HeyMate").font(.system(.headline, design: .rounded, weight: .semibold))
                PhoneMateFace(face: "MiloFutureIdle", size: 112).padding(.top, 28)
                Text(account.mayUseApp ? "Pair your Mac" : "Your mates,\nwherever you go.")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .accessibilityAddTraits(.isHeader)
                Text(account.mayUseApp
                     ? "Pair once for HeyMate and all your mates. On your Mac, open Settings → Devices → iPhone companion and show the pairing code."
                     : "Sign in with the Google account you use for HeyMate on your Mac.")
                    .foregroundStyle(HeyMatePalette.secondary)
                if !account.mayUseApp {
                    Button("Continue with Google", systemImage: "person.crop.circle") {
                        Task { await account.signInWithGoogle(using: GoogleAccountSignIn()) }
                    }
                    .buttonStyle(PhonePrimaryButton()).disabled(account.busy)
                } else if pilot.connection != nil {
                    Label(pilot.status ?? "Waiting for your Mac to confirm…", systemImage: "lock")
                    Button("Cancel pairing", role: .cancel) { pilot.disconnect() }
                } else {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button("Scan pairing code", systemImage: "qrcode.viewfinder") { scanner = true }
                            .buttonStyle(PhonePrimaryButton())
                    }
                    SecureField("Paste pairing code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(HeyMatePalette.field, in: RoundedRectangle(cornerRadius: 14))
                    Button("Pair with code") { pair(code) }.disabled(code.isEmpty)
                }
                if let problem = pilot.problem ?? account.message {
                    Label(problem, systemImage: "info.circle").font(.footnote).foregroundStyle(HeyMatePalette.secondary)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(26).frame(maxWidth: .infinity)
        }.background(PhoneWorkspaceBackground())
    }

    private func pair(_ scanned: String) {
        guard let uid = account.session?.uid else { return }
        pilot.pair(code: scanned, uid: uid)
        code = ""
    }
}

private struct PairScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    dataScanner.stopScanning()
                    found(payload)
                    return
                }
            }
        }
    }
}
