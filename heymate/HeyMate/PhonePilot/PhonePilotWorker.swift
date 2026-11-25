import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PhonePilotWorker: ObservableObject {
    private struct Pair: Codable {
        let channel: PhonePilotChannel
        var mateID: UUID? = nil // Original pilot fallback for requests without a mate ID.
        let handshakeID: UUID
        var sharedMateIDs: Set<UUID>? = nil
        var allowsMessages: Bool? = nil
        var sharesWorkspace: Bool? = nil

        var entireWorkspace: Bool? = nil

        var legacyMateIDs: Set<UUID> { sharedMateIDs ?? Set([mateID].compactMap { $0 }) }
    }

    private struct Offer {
        let invite: PhonePilotInvite
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        var channel: PhonePilotChannel {
            PhonePilotChannel(uid: invite.uid, pairID: invite.pairID, key: invite.secret)
        }
    }

    @Published private(set) var invitation: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isPaired = false
    @Published private(set) var problem: String?
    @Published private(set) var needsPairingUpgrade = false
    @Published private(set) var lastSuccessfulSync: Date?

    private weak var manager: CompanionManager?
    private let account = HeyMateAccount.shared
    private let store = PhonePilotKeychain<Pair>(account: "mac")
    private var pair: Pair?
    private var offer: Offer?
    private var loop: Task<Void, Never>?
    private var pollingDelay: Task<Void, Never>?
    private var generation = UUID()
    private var mailbox: PhonePilotMailbox?
    private var activeChatSyncUntil = Date.distantPast
    private var didRequestBrainCatalog = false

    func attach(_ manager: CompanionManager) {
        self.manager = manager
        guard let configuration = FirebaseAccountConfiguration.bundled,
              let uid = account.session?.uid, account.mayUseApp else { return }
        mailbox = PhonePilotMailbox(projectID: configuration.projectID)
        do {
            let saved = try store.load()
            if let saved, saved.channel.uid == uid {
                apply(saved)
                startLoop()
            }
        } catch { problem = PhonePilotError.secureStorage.localizedDescription }
    }

    func invite() {
        guard account.access == .verified, let uid = account.session?.uid, pair == nil else { return }
        stop()
        problem = nil
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let invite = PhonePilotInvite(uid: uid, secret: secret, publicKey: privateKey.publicKey.rawRepresentation)
        offer = Offer(invite: invite, privateKey: privateKey)
        invitation = invite.code
        expiresAt = invite.expiresAt
        startLoop()
    }

    func disconnect() {
        do {
            try store.clear()
            stop()
            pair = nil
            lastSuccessfulSync = nil
            isPaired = false
            needsPairingUpgrade = false
            problem = nil
            clearOffer()
        } catch { problem = PhonePilotError.secureStorage.localizedDescription }
    }

    private func includeCreatedMate(_ id: UUID) {
        guard var pair, pair.entireWorkspace != true else { return }
        pair.sharedMateIDs = pair.legacyMateIDs.union([id])
        saveChanges(pair)
    }

    func upgradePairing() {
        guard var pair else { return }
        pair.sharesWorkspace = true
        pair.allowsMessages = true
        pair.entireWorkspace = true
        saveChanges(pair)
    }

    private func saveChanges(_ pair: Pair) {
        do { try store.save(pair); apply(pair); problem = nil; pollingDelay?.cancel() }
        catch { problem = PhonePilotError.secureStorage.localizedDescription }
    }

    private func apply(_ pair: Pair) {
        if self.pair?.channel != pair.channel { lastSuccessfulSync = nil }
        self.pair = pair
        isPaired = true
        needsPairingUpgrade = pair.entireWorkspace != true
    }

    private func allowed(_ pair: Pair, manager: CompanionManager) -> Set<UUID> {
        let activeIDs = Set(manager.mates.lazy.filter { !$0.archived }.map(\.id))
        if pair.entireWorkspace == true { return activeIDs }
        let legacyIDs = pair.sharesWorkspace == true
            ? pair.legacyMateIDs.union([manager.mateDirectory.defaultMateID])
            : pair.legacyMateIDs
        return activeIDs.intersection(legacyIDs)
    }

    private func addCatalog(for pair: Pair, after cursor: UUID? = nil, to reply: inout PhonePilotReply) {
        guard let manager else { return }
        let gmail = CompanionManager.chatConnectorSelectionID(forComposioSlug: "gmail")
        let connected = manager.composioConnections.state(for: "gmail").isConnected
        let ids = allowed(pair, manager: manager)
        let mainID = manager.mateDirectory.defaultMateID
        func sortKey(_ id: UUID) -> String { id == mainID ? "" : id.uuidString }
        let ordered = manager.mates.filter { ids.contains($0.id) }.sorted { sortKey($0.id) < sortKey($1.id) }
        let start = cursor.map(sortKey)
        let encoder = JSONEncoder()
        var page: [PhonePilotMate] = []
        // Leave room for the workspace summary, profile, and encrypted envelope.
        var remainingBytes = 12_000
        for mate in ordered {
            if let start, sortKey(mate.id) <= start { continue }
            let entry = PhonePilotMate(id: mate.id, name: phoneClip(mate.name, bytes: 160),
                job: phoneClip(mate.job, bytes: 280),
                canCheckMail: connected && manager.isConnectorSelectionEnabled(gmail, for: mate),
                acceptsMessages: pair.allowsMessages == true, isMain: mate.id == mainID, face: mate.faceAssetName)
            guard let size = try? encoder.encode(entry).count, size + 1 <= remainingBytes else {
                reply.nextMateID = page.last?.id
                break
            }
            page.append(entry)
            remainingBytes -= size + 1
        }
        reply.mates = page
    }

    func stop() {
        generation = UUID()
        loop?.cancel()
        pollingDelay?.cancel()
        pollingDelay = nil
        loop = nil
    }

    private func clearOffer() {
        offer = nil
        invitation = nil
        expiresAt = nil
    }

    private func startLoop() {
        guard loop == nil, let mailbox else { return }
        if !didRequestBrainCatalog {
            didRequestBrainCatalog = true
            Task { await MateAgentSetupController.shared.check(.load()) }
        }
        let run = generation
        loop = Task { [weak self] in
            defer { if self?.generation == run { self?.loop = nil } }
            while let self, !Task.isCancelled, self.generation == run {
                if let offer = self.offer, offer.invite.expiresAt <= .now { self.clearOffer() }
                guard let channel = self.pair?.channel ?? self.offer?.channel,
                      self.account.session?.uid == channel.uid, self.account.mayUseApp else { return }
                var didReceiveTasks = false
                do {
                    let credentials = try await self.account.phonePilotSession()
                    guard !Task.isCancelled, self.generation == run, credentials.uid == channel.uid else { return }
                    let tasks = try await mailbox.pending(channel, token: credentials.idToken, statuses: ["queued", "running"])
                    for task in tasks {
                        try Task.checkCancellation()
                        do {
                            try await self.process(task, channel: channel, mailbox: mailbox, token: credentials.idToken)
                        } catch PhonePilotError.conflict { continue }
                    }
                    self.problem = nil
                    didReceiveTasks = !tasks.isEmpty
                } catch is CancellationError { return }
                catch {
                    if !Task.isCancelled {
                        self.problem = (error as? PhonePilotError)?.localizedDescription ?? PhonePilotError.unavailable.localizedDescription
                    }
                }
                let active = self.offer != nil || self.activeChatSyncUntil > .now
                let delay = active ? 3 : (didReceiveTasks ? 5 : 10)
                guard !Task.isCancelled, self.generation == run else { return }
                let wait = Task<Void, Never> { try? await Task.sleep(for: .seconds(delay)) }
                self.pollingDelay = wait
                await wait.value
                if self.generation == run { self.pollingDelay = nil }
            }
        }
    }

    private func process(_ task: PhonePilotTask, channel: PhonePilotChannel, mailbox: PhonePilotMailbox,
                         token: String) async throws {
        if let existing = pair, existing.handshakeID == task.id {
            try await finish(task, channel: existing.channel, mailbox: mailbox, token: token, reply: pairedReply(existing))
            return
        }
        if pair == nil, let offer, offer.invite.expiresAt > .now {
            guard let request = try? channel.open(PhonePilotRequest.self, data: task.request,
                                                  taskID: task.id, direction: .pairingRequest),
                  request.kind == .pair, let phoneKey = request.phonePublicKey,
                  let derivedKey = try? offer.invite.key(privateKey: offer.privateKey, peer: phoneKey) else {
                if task.status == "queued" { try await mailbox.delete(channel, task: task, token: token) }
                return
            }
            let paired = Pair(channel: .init(uid: channel.uid, pairID: channel.pairID, key: derivedKey),
                              handshakeID: task.id, allowsMessages: true, sharesWorkspace: true,
                              entireWorkspace: true)
            try store.save(paired)
            apply(paired)
            clearOffer()
            try await finish(task, channel: paired.channel, mailbox: mailbox, token: token, reply: pairedReply(paired))
            return
        }

        guard let pair, pair.channel.pairID == channel.pairID else { return }
        if task.status == "running" {
            try await finish(task, channel: pair.channel, mailbox: mailbox, token: token,
                             reply: .init(text: "The Mac was interrupted. Send a new request."), failed: true)
            return
        }
        guard let request = try? pair.channel.open(PhonePilotRequest.self, data: task.request, taskID: task.id, direction: .request),
              request.kind != .pair, request.phonePublicKey == nil else {
            try await mailbox.delete(channel, task: task, token: token)
            return
        }
        guard task.createdAt.timeIntervalSinceNow >= -86400 else {
            try await finish(task, channel: channel, mailbox: mailbox, token: token,
                             reply: .init(text: "The request expired. Send a new one when you’re ready."), failed: true)
            return
        }
        guard let running = try await claim(task, channel: channel, mailbox: mailbox, token: token) else { return }
        try Task.checkCancellation()
        guard let current = self.pair, current.channel == pair.channel else { return }
        let report = await reply(to: request, pair: current, mailbox: mailbox, token: token)
        if report.reply.thread?.chat.busy == true { activeChatSyncUntil = .now.addingTimeInterval(30) }
        try Task.checkCancellation()
        let currentAccount = try await account.phonePilotSession()
        guard currentAccount.uid == channel.uid, self.pair?.channel == channel else { return }
        try await finish(running, channel: channel, mailbox: mailbox, token: currentAccount.idToken,
                         reply: report.reply, failed: !report.success)
        if request.kind == .message, !report.success {
            deliverActivityPush(request.activityPush, stage: .failed, for: channel)
        }
        if let attachments = request.attachments, PhoneAttachment.validate(attachments) {
            try? await mailbox.deleteAttachments(attachments.flatMap(\.chunks), channel: channel,
                                                 token: currentAccount.idToken)
        }
    }

    private func deliverActivityPush(_ target: PhoneLiveActivityTarget?, stage: PhoneActivityPush.Stage,
                                     for channel: PhonePilotChannel) {
        guard let target, target.hasValidToken else { return }
        Task { [weak self] in
            await PhoneActivityPush.shared.finish(target, stage: stage) {
                self?.pair?.channel == channel && self?.account.session?.uid == channel.uid
                    && self?.account.mayUseApp == true
            }
        }
    }

    private func pairedReply(_ pair: Pair) -> PhonePilotReply {
        let workspace = manager.map { $0.phoneWorkspace(shared: pair.sharesWorkspace == true, mateIDs: allowed(pair, manager: $0)) }
        // Older iPhone builds use mateName as the pairing acknowledgement.
        var reply = PhonePilotReply(text: "iPhone paired", mateName: "HeyMate", workspace: workspace)
        addCatalog(for: pair, to: &reply)
        return reply
    }

    private func reply(to request: PhonePilotRequest, pair: Pair, mailbox: PhonePilotMailbox, token: String) async -> (reply: PhonePilotReply, success: Bool) {
        guard let manager else { return (.init(text: "Open HeyMate on your Mac."), false) }
        if request.kind == .mates, let cursor = request.before {
            var reply = PhonePilotReply(text: "Mates updated")
            addCatalog(for: pair, after: cursor, to: &reply)
            return (reply, true)
        }
        if request.kind == .mates || request.kind == .workspace {
            let isShared = pair.sharesWorkspace == true
            let ids = allowed(pair, manager: manager)
            let workspace = manager.phoneWorkspace(shared: isShared, mateIDs: ids)
            let profile = request.mateID.flatMap { isShared && ids.contains($0) ? manager.phoneProfile($0) : nil }
            var reply = PhonePilotReply(text: "Workspace updated", workspace: workspace, profile: profile)
            addCatalog(for: pair, to: &reply)
            return (reply, true)
        }
        if request.kind != .unreadMail && request.kind != .message {
            guard pair.sharesWorkspace == true else {
                return (.init(text: "Choose Enable workspace access in iPhone companion settings on your Mac."), false)
            }
            let ids = allowed(pair, manager: manager)
            let result = await manager.phoneWorkspaceRequest(request, mateIDs: ids, allowsMessages: pair.allowsMessages == true)
            if let created = result.createdMate { includeCreatedMate(created) }
            var reply = result.reply
            if request.kind == .createMate || request.kind == .saveProfile { addCatalog(for: self.pair ?? pair, to: &reply) }
            return (reply, result.success)
        }
        let mateID = request.mateID ?? pair.mateID ?? manager.mateDirectory.defaultMateID
        guard allowed(pair, manager: manager).contains(mateID) else {
            var reply = PhonePilotReply(text: "This mate isn’t available on this iPhone.")
            addCatalog(for: pair, to: &reply)
            return (reply, false)
        }
        let result: (text: String, success: Bool)
        switch request.kind {
        case .unreadMail:
            result = await manager.phonePilotUnreadMail(mateID: mateID)
        case .message:
            guard pair.allowsMessages == true else { return (.init(text: "Choose Enable workspace access in iPhone companion settings on your Mac."), false) }
            guard let text = request.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= PhonePilotRequest.messageLimit else {
                return (.init(text: "That message was empty or too long."), false)
            }
            if request.chatID != nil, pair.sharesWorkspace != true {
                return (.init(text: "Choose Enable workspace access in iPhone companion settings on your Mac."), false)
            }
            if let chatID = request.chatID, request.followsTranscript == true {
                if request.startsNewChat == true, !manager.preparePhoneCompanionDraft(mateID: mateID, chatID: chatID) {
                    return (.init(text: "Couldn’t create this chat. Start a new conversation and try again."), false)
                }
                if manager.mateInboxChatIsBusy(chatID) {
                    return (.init(text: "This chat already has a turn in progress."), false)
                }
                let brain = request.brain.flatMap { manager.phoneBrainOverride($0) }
                if request.brain != nil && brain == nil {
                    return (.init(text: "That brain, model, or effort is no longer available on your Mac."), false)
                }
                do {
                    let attachments = request.attachments ?? []
                    let content = try await loadAttachments(attachments, pair: pair, mailbox: mailbox, token: token)
                    guard self.pair?.channel == pair.channel, !Task.isCancelled else {
                        return (.init(text: "The iPhone connection changed."), false)
                    }
                    let prepared = try manager.preparePhoneCompanionAttachments(content, mateID: mateID)
                    let prompt = MateChatDocuments.messageText(text, documents: prepared.documents)
                    result = manager.startPhoneCompanionTurn(prompt, mateID: mateID, chatID: chatID,
                                                             brain: brain, images: prepared.images) { [weak self] outcome in
                        let stage: PhoneActivityPush.Stage
                        switch outcome {
                        case .replied: stage = .ready
                        case .failed: stage = .failed
                        case .stopped: stage = request.activityPush?.supportsStoppedStage == true ? .stopped : .failed
                        }
                        self?.deliverActivityPush(request.activityPush, stage: stage, for: pair.channel)
                    }
                } catch {
                    return (.init(text: "The Mac couldn’t open one of these attachments. Check the file and try again."), false)
                }
            } else {
                result = await manager.phoneCompanionMessage(text, mateID: mateID, chatID: request.chatID)
            }
        default:
            return (.init(text: "This request isn’t available."), false)
        }
        let thread = request.chatID.flatMap { manager.phoneThread(mateID: mateID, chatID: $0, before: nil) }
        return (.init(text: phoneClip(result.text, bytes: 4_000), thread: thread), result.success)
    }

    private func loadAttachments(_ files: [PhoneAttachment], pair: Pair, mailbox: PhonePilotMailbox,
                                 token: String) async throws -> [(name: String, data: Data)] {
        guard PhoneAttachment.validate(files) else { throw PhonePilotError.invalidResponse }
        var content: [(String, Data)] = []
        for file in files {
            var data = Data()
            data.reserveCapacity(file.size)
            for start in stride(from: 0, to: file.chunks.count, by: PhoneAttachment.uploadBatchSize) {
                try Task.checkCancellation()
                let ids = Array(file.chunks[start..<min(start + PhoneAttachment.uploadBatchSize, file.chunks.count)])
                let chunks = try await mailbox.attachmentData(ids, channel: pair.channel, token: token)
                for id in ids {
                    guard let chunk = chunks[id], chunk.count == min(PhoneAttachment.chunkSize, file.size - data.count) else {
                        throw PhonePilotError.invalidResponse
                    }
                    data.append(chunk)
                }
            }
            content.append((file.name, data))
        }
        return content
    }

    private func claim(_ task: PhonePilotTask, channel: PhonePilotChannel, mailbox: PhonePilotMailbox,
                       token: String) async throws -> PhonePilotTask? {
        if task.status == "running" { return task }
        try await mailbox.transition(channel, task: task, status: "running", token: token)
        let claimed = try await mailbox.task(channel, id: task.id, token: token)
        return claimed?.status == "running" ? claimed : nil
    }

    private func finish(_ task: PhonePilotTask, channel: PhonePilotChannel, mailbox: PhonePilotMailbox,
                        token: String, reply: PhonePilotReply, failed: Bool = false) async throws {
        guard let running = try await claim(task, channel: channel, mailbox: mailbox, token: token) else { return }
        let data = try channel.seal(reply, taskID: task.id, direction: .result)
        try await mailbox.transition(channel, task: running, status: failed ? "failed" : "completed", result: data, token: token)
        if !failed, !Task.isCancelled, pair?.channel == channel {
            lastSuccessfulSync = .now
        }
    }
}

extension CompanionManager {
    func preparePhoneCompanionAttachments(_ files: [(name: String, data: Data)], mateID: UUID) throws
        -> (images: [ChatImageAttachment], documents: [MateChatDocument]) {
        guard !files.isEmpty else { return ([], []) }
        let folder = URL.temporaryDirectory.appending(path: "heymate-phone-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var images: [ChatImageAttachment] = []
        var documents: [URL] = []
        for (index, file) in files.enumerated() {
            let path = folder.appending(path: String(index), directoryHint: .isDirectory).appending(path: file.name)
            if UTType(filenameExtension: path.pathExtension)?.conforms(to: .image) == true {
                guard images.count < ChatImageAttachment.maximumCount else { throw PhonePilotError.invalidResponse }
                images.append(try ChatImageAttachment.make(from: file.data, fileName: file.name))
            } else {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: false)
                try file.data.write(to: path, options: .atomic)
                documents.append(path)
            }
        }
        guard !documents.isEmpty else { return (images, []) }
        ensureMateFolder(id: mateID)
        guard let path = mates.first(where: { $0.id == mateID })?.folderPath else { throw PhonePilotError.invalidResponse }
        let copied = MateChatDocuments.attach(documents, into: URL(fileURLWithPath: path, isDirectory: true))
        guard copied.problems.isEmpty else { throw PhonePilotError.unavailable }
        return (images, copied.documents)
    }

    func startPhoneCompanionTurn(_ text: String, mateID: UUID, chatID: UUID,
                                 brain: MateAgentServeSession.BrainOverride? = nil,
                                 images: [ChatImageAttachment] = [],
                                 onFinished: ((BackgroundChatOutcome) -> Void)? = nil) -> (text: String, success: Bool) {
        guard phoneCompanionChats(for: mateID).contains(where: { $0.id == chatID }) else {
            return ("This chat is no longer available on the Mac.", false)
        }
        guard resumeMateChatInBackground(mateID: mateID, chatID: chatID, userMessage: text, modelPrompt: text,
                                         brain: brain, images: images, onFinished: onFinished) else {
            return ("This chat already has a turn in progress.", false)
        }
        return ("Message sent", true)
    }

    func phoneCompanionMessage(_ text: String, mateID: UUID, chatID requestedChatID: UUID? = nil) async -> (text: String, success: Bool) {
        guard !Task.isCancelled else { return ("The request was canceled.", false) }
        let chatID = requestedChatID ?? mateChatForInboxAction(mateID: mateID)
        let known = Set(mateInbox.work.filter { $0.chatID == chatID }.map(\.id))
        let started = startPhoneCompanionTurn(text, mateID: mateID, chatID: chatID)
        guard started.success else { return started }
        let deadline = Date.now.addingTimeInterval(25 * 60)
        while Date.now < deadline, !Task.isCancelled {
            if let work = mateInbox.work.first(where: { $0.chatID == chatID && !known.contains($0.id) }) {
                switch work.state {
                case .needsInput:
                    return ((work.result ?? "This mate needs your input.") + " Open HeyMate on your Mac to continue.", true)
                case .resultReady:
                    return (work.result ?? "Finished. Open the mate’s chat on your Mac for details.", work.displayState != .failed)
                case .failed, .stopped:
                    return (work.result ?? "The mate couldn’t finish this request. Check its chat on your Mac.", false)
                case .running, .resumed:
                    break
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return ("Open the mate’s chat on your Mac to see the latest status.", false)
    }

    /// One fixed read against the connected Gmail account. The phone supplies
    /// neither a provider URL nor a prompt, query, arguments, or account ID.
    func phonePilotUnreadMail(mateID: UUID) async -> (text: String, success: Bool) {
        guard let mate = mates.first(where: { $0.id == mateID && !$0.archived }) else {
            return ("This mate is no longer available on the Mac.", false)
        }
        let gmail = Self.chatConnectorSelectionID(forComposioSlug: "gmail")
        guard isConnectorSelectionEnabled(gmail, for: mate),
              composioConnections.state(for: "gmail").isConnected,
              let connected = composioConnections.records["gmail"],
              let apiKey = composioConnections.apiKey else {
            return ("Connect Gmail for \(mate.name) in HeyMate on the Mac, then try again.", false)
        }
        let policy = ApprovalMode.current(forMateID: mateID).connectorPolicy(
            connectorStore.record(for: ComposioSessionStore.connectorID).approvalPolicy)
        guard !policy.requiresApproval(forRisk: .readOnly) else {
            return ("Gmail reads for \(mate.name) require approval on the Mac. Open HeyMate to check your inbox.", false)
        }

        do {
            let count = try await PhonePilotGmail.unreadSample(accountID: connected.connectedAccountID,
                userID: ComposioSessionStore.userID(), apiKey: apiKey)
            let detail = switch count {
            case 0: "No unread messages in your inbox."
            case 1: "Found one unread message in your inbox."
            case 6: "Found at least six unread messages in your inbox."
            default: "Found \(count) unread messages in your inbox."
            }
            return (detail, true)
        } catch {
            return ("Gmail couldn’t complete this inbox check. Check the Gmail connection on your Mac.", false)
        }
    }
}

enum PhonePilotGmail {
    static func unreadSample(accountID: String, userID: String, apiKey: String) async throws -> Int {
        let url = URL(string: "https://backend.composio.dev/api/v3.1/tools/execute/GMAIL_FETCH_EMAILS")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "connected_account_id": accountID, "user_id": userID, "version": "latest",
            "arguments": [
                "query": "in:inbox is:unread", "max_results": 6,
                "include_payload": false, "verbose": false, "only_ids": true
            ]
        ])
        let session = URLSession(configuration: .ephemeral, delegate: PhonePilotNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              wrapper["successful"] as? Bool == true,
              let result = wrapper["data"] as? [String: Any],
              result["resultSizeEstimate"] is Int else { throw PhonePilotError.invalidResponse }
        let count = (result["messages"] as? [[String: Any]])?.count ?? 0
        return count == 6 || result["nextPageToken"] != nil ? 6 : count
    }
}
