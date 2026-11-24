import SwiftUI

private struct PhoneAccentHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var phoneAccentHex: String? {
        get { self[PhoneAccentHexKey.self] }
        set { self[PhoneAccentHexKey.self] = newValue }
    }
}

struct PhoneWorkspaceBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: HeyMatePalette.workspaceStops, startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                LinearGradient(colors: [.white.opacity(0.035), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(proxy.size.height * 0.35, 280))
            }
            if let grain = Self.grain {
                Image(decorative: grain, scale: 2).resizable(resizingMode: .tile)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let grain: CGImage? = {
        let side = 128
        let maximumAlpha: UInt32 = 6
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E37_79B9
        for index in 0..<(side * side) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let alpha = UInt8((seed >> 24) * maximumAlpha / 255)
            let position = index * 4
            pixels[position] = alpha
            pixels[position + 1] = alpha
            pixels[position + 2] = alpha
            pixels[position + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

struct PhoneMateFace: View {
    @Environment(\.phoneAccentHex) private var accentHex
    let face: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let face, let image = UIImage(named: face) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                UnevenRoundedRectangle(topLeadingRadius: size * 0.38, bottomLeadingRadius: size * 0.35,
                                       bottomTrailingRadius: size * 0.45, topTrailingRadius: size * 0.35)
                    .fill(LinearGradient(colors: [HeyMatePalette.primary, HeyMatePalette.accent(accentHex),
                                                  HeyMatePalette.accent(accentHex, towardBlack: 0.34)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        HStack(spacing: size * 0.15) {
                            Capsule().fill(.black).frame(width: size * 0.055, height: size * 0.115)
                            Capsule().fill(.black).frame(width: size * 0.055, height: size * 0.115)
                        }
                    }
                    .frame(width: size * 0.88, height: size * 0.64)
                    .rotationEffect(.degrees(-9))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PhonePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.phoneAccentHex) private var accentHex

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 14)
            .foregroundStyle(enabled ? HeyMatePalette.glassInk : HeyMatePalette.primary.opacity(0.38))
            .background(enabled ? HeyMatePalette.accent(accentHex, towardBlack: configuration.isPressed ? 0.18 : 0) : HeyMatePalette.surface, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct PhoneWorkspaceHome: View {
    enum Page: String, CaseIterable {
        case main = "HeyMate", mates = "Mates", routines = "Routines", inbox = "Inbox"

        var icon: String {
            switch self {
            case .main: "bubble.left.and.bubble.right"
            case .mates: "person.2"
            case .routines: "clock.arrow.circlepath"
            case .inbox: "tray"
            }
        }
    }

    private enum Route: Hashable {
        case mate(UUID)
        case chat(PhoneChat, draft: Bool)
    }

    private enum Sheet: Identifiable {
        case connection
        case profile(PhonePilotMate)
        case create
        case routine(PhoneRoutine?)
        case answer(PhoneQuestion)

        var id: String {
            switch self {
            case .connection: "connection"
            case .profile(let mate): "profile-" + mate.id.uuidString
            case .create: "create"
            case .routine(let routine): "routine-" + (routine?.id.uuidString ?? "new")
            case .answer(let question): "answer-" + question.id.uuidString
            }
        }
    }

    @Environment(\.phoneAccentHex) private var accentHex
    @Environment(\.scenePhase) private var phase
    @ObservedObject var pilot: PhonePilotModel
    let signOut: () -> Void
    @State private var page = Page.main
    @State private var path: [Route] = []
    @State private var sheet: Sheet?
    @State private var requestedChats = Set<UUID>()
    @AppStorage(PhoneLiveActivity.enabledKey) private var liveActivitiesEnabled = true

    private var mates: [PhonePilotMate] { pilot.connection?.mates ?? [] }
    private var mainMate: PhonePilotMate? {
        mates.first { $0.id == pilot.workspace?.mainMateID } ?? mates.first { $0.isMain == true }
    }
    private var shared: Bool { pilot.workspace?.sharing == true }
    private var waiting: Bool { pilot.watchID != nil }
    private var accent: Color { HeyMatePalette.accent(accentHex, towardWhite: 0.28) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    masthead
                    feedback
                    pageContent
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .refreshable { refresh() }
            .background(PhoneWorkspaceBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .mate(let id):
                    if let mate = mates.first(where: { $0.id == id }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                mateHero(mate)
                                feedback
                                chatList(mate)
                            }
                            .padding(20)
                        }
                        .background(PhoneWorkspaceBackground())
                        .navigationTitle(mate.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                        .task(id: waiting) { loadChatsIfNeeded(mate.id) }
                    }
                case .chat(let chat, let draft):
                    PhoneChatScreen(pilot: pilot, chat: chat,
                                    allowsMessages: mates.first { $0.id == chat.mateID }?.acceptsMessages == true,
                                    startsAsDraft: draft)
                        .onAppear { pilot.visibleChatID = chat.id }
                        .onDisappear { if pilot.visibleChatID == chat.id { pilot.visibleChatID = nil } }
                }
            }
        }
        .onChange(of: pilot.openedChat) { _, chat in
            if let chat, path.last != .chat(chat, draft: false) { path.append(.chat(chat, draft: false)) }
        }
        .onChange(of: pilot.workspace) { _, workspace in
            if workspace?.sharing == false { path = []; requestedChats = [] }
            openCompanionLink()
        }
        .onChange(of: pilot.companionLink, initial: true) { _, _ in openCompanionLink() }
        .onChange(of: mates) { _, _ in openCompanionLink() }
        .onChange(of: liveActivitiesEnabled) { _, enabled in if !enabled { PhoneLiveActivity.clear() } }
        .onChange(of: waiting) { _, waiting in
            guard !waiting, page == .main, path.isEmpty, let id = mainMate?.id else { return }
            loadChatsIfNeeded(id)
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard path.isEmpty, sheet == nil, !waiting else { continue }
                if page == .main, let id = mainMate?.id {
                    if shared { loadChats(id, quietly: true) }
                }
            }
        }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
    }

    private func newChatRoute(for mateID: UUID) -> Route {
        .chat(PhoneChat(id: UUID(), mateID: mateID, title: "New chat", updatedAt: .now, busy: false), draft: true)
    }

    private func openCompanionLink() {
        guard shared, let link = pilot.companionLink else { return }
        let route: Route
        switch link {
        case .newChat:
            guard let mate = mainMate, mate.acceptsMessages else { return }
            route = newChatRoute(for: mate.id)
        case .chat(let mateID, let chatID):
            guard mates.contains(where: { $0.id == mateID }) else { return }
            let cached = pilot.threads[chatID]?.chat ?? pilot.chats[mateID]?.first { $0.id == chatID }
            if case .chat(let current, _) = path.last, current.id == chatID, current.mateID == mateID {
                pilot.companionLink = nil
                return
            }
            route = .chat(cached ?? PhoneChat(id: chatID, mateID: mateID, title: "Chat", updatedAt: .now, busy: false),
                          draft: false)
        }
        pilot.companionLink = nil
        sheet = nil
        page = .main
        path = [route]
    }

    private var masthead: some View {
        HStack {
            Label("HeyMate", systemImage: "capsule.fill")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Spacer()
            Button { pilot.loadMates() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 42, height: 42)
            }
            .accessibilityLabel("Refresh from Mac").disabled(waiting)
            Button { sheet = .connection } label: {
                Image(systemName: "gearshape").frame(width: 42, height: 42)
                    .background(HeyMatePalette.surface, in: Circle())
            }
            .accessibilityLabel("Connection settings")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { tab in
                Button {
                    page = tab
                    switch tab {
                    case .main:
                        if let id = mainMate?.id { loadChatsIfNeeded(id) }
                    case .routines:
                        if shared, pilot.routines == nil { request(.init(kind: .routines), "Load routines") }
                    case .mates, .inbox: break
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: .medium))
                        Text(tab.rawValue).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(tab == page ? accent : HeyMatePalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(tab == page ? HeyMatePalette.accent(accentHex).opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == page ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        .background(HeyMatePalette.rail)
    }

    @ViewBuilder private var feedback: some View {
        if let status = pilot.status {
            Label(status, systemImage: "arrow.left.arrow.right")
                .font(.subheadline).foregroundStyle(accent)
                .accessibilityIdentifier("phoneRequestStatus")
        }
        if let message = pilot.problem ?? pilot.notice {
            Label(message, systemImage: "info.circle")
                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(HeyMatePalette.surface, in: RoundedRectangle(cornerRadius: 13))
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .main:
            if let mainMate, shared {
                mateHero(mainMate)
                chatList(mainMate)
            } else {
                pageTitle("HeyMate chats", "Start a conversation or pick up an existing one from your Mac.")
                PhoneMateFace(face: "MiloFutureIdle", size: 130)
                syncPrompt
            }
        case .mates:
            HStack(alignment: .top) {
                pageTitle("Mates", "Choose who you want to work with.")
                if shared {
                    Button { sheet = .create } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                            .background(HeyMatePalette.surface, in: Circle())
                    }
                    .accessibilityLabel("Create mate")
                }
            }
            let sharedMates = mates.filter { $0.id != mainMate?.id && $0.isMain != true }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(sharedMates) { mate in
                Button { path.append(.mate(mate.id)) } label: { mateRow(mate) }.buttonStyle(.plain)
            }
            if sharedMates.isEmpty {
                if shared {
                    Text("Mates from your Mac will appear here.").foregroundStyle(HeyMatePalette.secondary)
                } else { syncPrompt }
            }
        case .routines:
            HStack(alignment: .top) {
                pageTitle("Routines", "Recurring work runs on your Mac.")
                if shared {
                    Button { sheet = .routine(nil) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                            .background(HeyMatePalette.surface, in: Circle())
                    }
                    .accessibilityLabel("Create routine")
                }
            }
            if shared {
                if let routines = pilot.routines {
                    ForEach(routines) { routine in routineRow(routine) }
                    if routines.isEmpty { Text("No routines for your shared mates yet.").foregroundStyle(HeyMatePalette.secondary) }
                } else {
                    Button("Load routines") { request(.init(kind: .routines), "Load routines") }.disabled(waiting)
                }
            } else { syncPrompt }
        case .inbox:
            pageTitle("Inbox", "Questions from your mates and recent phone activity.")
            if let questions = pilot.workspace?.questions, !questions.isEmpty {
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.mateName).font(.headline)
                        Text(question.text)
                        Button("Answer", systemImage: "arrow.turn.up.left") { sheet = .answer(question) }
                    }
                    .phoneCard()
                }
            }
            if let activity = pilot.connection?.activity, !activity.isEmpty {
                ForEach(activity) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(item.name, systemImage: item.failed ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.headline)
                        Text(item.title).foregroundStyle(HeyMatePalette.secondary)
                        Text(item.reply)
                        Text(item.time, style: .relative).font(.caption).foregroundStyle(HeyMatePalette.secondary)
                    }.phoneCard()
                }
            } else if pilot.workspace?.questions.isEmpty != false {
                Text("Nothing needs your attention.").foregroundStyle(HeyMatePalette.secondary)
            }
        }
    }

    private var syncPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pilot.workspace?.sharing == false {
                Label("Update your pairing", systemImage: "lock").font(.headline)
                Text("On your Mac, open Settings → Devices → iPhone companion and choose Enable workspace access.")
                    .font(.subheadline).foregroundStyle(HeyMatePalette.secondary)
            } else {
                Label("Waiting for your Mac", systemImage: "macbook").font(.headline)
                Text("Keep HeyMate open on an awake, online Mac. Then reload your chats.")
                    .font(.subheadline).foregroundStyle(HeyMatePalette.secondary)
            }
            Button("Sync chats now", systemImage: "arrow.clockwise") { pilot.loadMates() }.disabled(waiting)
        }.phoneCard()
    }

    private func pageTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            Text(detail).foregroundStyle(HeyMatePalette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mateHero(_ mate: PhonePilotMate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                pageTitle(mate.name, mate.job)
                if shared {
                    Button("Customize", systemImage: "slider.horizontal.3") {
                        if pilot.profiles[mate.id] == nil {
                            request(.init(kind: .workspace, mateID: mate.id), "Load profile")
                        }
                        sheet = .profile(mate)
                    }
                    .font(.subheadline).disabled(waiting)
                }
            }
            PhoneMateFace(face: mate.face ?? (mate.isMain == true ? "MiloFutureIdle" : nil), size: 112)
        }
        .padding(.vertical, 8)
    }

    private func mateRow(_ mate: PhonePilotMate) -> some View {
        HStack(spacing: 12) {
            PhoneMateFace(face: mate.face, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(mate.name).font(.system(.headline, design: .rounded, weight: .bold))
                Text(mate.job).font(.subheadline).foregroundStyle(HeyMatePalette.secondary).lineLimit(2)
            }
            Spacer()
            Label("Chats", systemImage: "bubble.left")
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
        }
        .phoneCard()
    }

    @ViewBuilder private func chatList(_ mate: PhonePilotMate) -> some View {
        if shared {
            Text("Chats").font(.system(.title2, design: .rounded, weight: .bold)).accessibilityAddTraits(.isHeader)
            Button("New chat with \(mate.name)", systemImage: "square.and.pencil") {
                path.append(newChatRoute(for: mate.id))
            }.buttonStyle(PhonePrimaryButton()).disabled(!mate.acceptsMessages)
            if let chats = pilot.chats[mate.id] {
                if chats.isEmpty { Text("No conversations yet.").foregroundStyle(HeyMatePalette.secondary) }
                ForEach(chats) { chat in
                    Button {
                        path.append(.chat(chat, draft: false))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(chat.title).font(.headline)
                                Text(chat.updatedAt, style: .relative).font(.caption).foregroundStyle(HeyMatePalette.secondary)
                            }
                            Spacer()
                            Image(systemName: chat.busy ? "clock" : "chevron.right").foregroundStyle(HeyMatePalette.secondary)
                        }.phoneCard()
                    }.buttonStyle(.plain)
                }
            }
            if !mate.acceptsMessages {
                Text("Update this pairing on your Mac to send replies.")
                    .font(.footnote).foregroundStyle(HeyMatePalette.secondary)
            }
            Button("Refresh chats", systemImage: "arrow.clockwise") { loadChats(mate.id) }.disabled(waiting)
        } else { syncPrompt }
        if mate.canCheckMail {
            Button("Check unread mail", systemImage: "tray") { pilot.checkMail(mateID: mate.id) }
                .buttonStyle(.bordered).disabled(waiting)
        }
    }

    private func routineRow(_ routine: PhoneRoutine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(routine.task).font(.headline)
            Text([mates.first { $0.id == routine.mateID }?.name, routine.scheduleLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(HeyMatePalette.secondary)
            if routine.enabled {
                Text("Next run \(routine.next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(HeyMatePalette.secondary)
            } else {
                Text("Paused").font(.caption).foregroundStyle(HeyMatePalette.secondary)
            }
            if let result = routine.lastResult { Text(result).font(.subheadline) }
            HStack {
                Button("Run now") { request(.init(kind: .routineAction, itemID: routine.id, action: .run), "Run routine") }
                Button(routine.enabled ? "Pause" : "Resume") {
                    request(.init(kind: .routineAction, itemID: routine.id, action: routine.enabled ? .pause : .resume), "Change routine")
                }
                Spacer()
                Button("Edit") { sheet = .routine(routine) }
            }.buttonStyle(.borderless).font(.subheadline).disabled(waiting)
        }.phoneCard()
    }

    private func loadChats(_ id: UUID, quietly: Bool = false) {
        guard shared else { return }
        pilot.enqueue(.init(kind: .chats, mateID: id), title: "Load chats", quietly: quietly)
    }

    private func loadChatsIfNeeded(_ id: UUID) {
        guard shared, !waiting, pilot.chats[id] == nil, !requestedChats.contains(id) else { return }
        if pilot.enqueue(.init(kind: .chats, mateID: id), title: "Load chats") { requestedChats.insert(id) }
    }

    private func refresh() {
        switch page {
        case .main where shared:
            if let id = mainMate?.id { loadChats(id) }
        case .routines where shared: request(.init(kind: .routines), "Refresh routines")
        case .main, .mates, .routines, .inbox: pilot.loadMates()
        }
    }

    private func request(_ request: PhonePilotRequest, _ title: String) { pilot.enqueue(request, title: title) }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .connection:
            PhoneEditorFrame(title: "Connection") {
                Label("Paired with your Mac", systemImage: "lock.shield")
                Text("Your Mac runs the work. Keep it awake and online. Sensitive action approvals stay in HeyMate on the Mac.")
                    .foregroundStyle(HeyMatePalette.secondary)
                Toggle("Show chat Live Activities", isOn: $liveActivitiesEnabled)
                Link("Privacy policy", destination: URL(string: "https://sayheymate.com/privacy")!)
                Button("Sign out", action: signOut)
                Button("Forget this Mac", role: .destructive) {
                    pilot.disconnect()
                    self.sheet = nil
                }
            }
        case .profile(let mate):
            if let profile = pilot.profiles[mate.id] {
                PhoneProfileEditor(title: "Customize \(mate.name)", draft: profile) { edited in
                    if pilot.enqueue(.init(kind: .saveProfile, mateID: mate.id, profile: edited), title: "Save profile") {
                        self.sheet = nil
                    }
                }
            } else {
                PhoneEditorFrame(title: "Customize \(mate.name)") {
                    Text(pilot.status ?? pilot.problem ?? pilot.notice ?? "Waiting for your Mac…")
                    Button("Retry") { request(.init(kind: .workspace, mateID: mate.id), "Load profile") }.disabled(waiting)
                }
            }
        case .create:
            PhoneProfileEditor(title: "New mate", draft: .init(name: "", job: "", personality: "")) { profile in
                if pilot.enqueue(.init(kind: .createMate, profile: profile), title: "Create mate") { self.sheet = nil }
            }
        case .routine(let routine):
            PhoneRoutineEditor(routine: routine, mates: mates) { mateID, text, schedule in
                if pilot.enqueue(.init(kind: .saveRoutine, mateID: mateID, message: text,
                                       itemID: routine?.id, schedule: schedule), title: "Save routine") { self.sheet = nil }
            }
        case .answer(let question):
            PhoneAnswerEditor(question: question) { answer in
                if pilot.enqueue(.init(kind: .answer, message: answer, itemID: question.id), title: "Answer question") {
                    self.sheet = nil
                }
            }
        }
    }
}

extension View {
    func phoneCard() -> some View {
        self.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(HeyMatePalette.surface, in: RoundedRectangle(cornerRadius: 17))
    }
}
