import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhoneChatScreen: View {
    @ObservedObject var pilot: PhonePilotModel
    let chat: PhoneChat
    let allowsMessages: Bool
    let startsAsDraft: Bool
    @Environment(\.phoneAccentHex) private var accentHex
    @Environment(\.scenePhase) private var phase
    @State private var draft = ""
    @State private var showsLink = false
    @State private var link = ""
    @State private var requestedTranscript = false
    @State private var pickingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var files: [PhonePilotModel.LocalAttachment] = []
    @State private var attachmentError: String?
    @State private var choosingBrain = false
    @State private var brain: PhoneBrainChoice?

    private var thread: PhoneThread? { pilot.threads[chat.id] }
    private var waiting: Bool { pilot.watchID != nil || pilot.uploading }
    private var brains: [PhoneBrainOption] { pilot.workspace?.brains ?? [] }
    private var canAttach: Bool { pilot.workspace?.supportsAttachments == true }
    private var canSend: Bool {
        !waiting && !turnIsRunning && draft.count <= PhonePilotRequest.messageLimit
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
    }
    private var isDraft: Bool { startsAsDraft && thread == nil }
    private var turnIsRunning: Bool { thread?.chat.busy == true }
    private var stoppableChat: PhoneChat? {
        guard pilot.workspace?.supportsStopReply == true, let chat = thread?.chat,
              chat.busy, chat.turnID != nil else { return nil }
        return chat
    }
    private var rawMessages: [PhoneChatMessage] { thread?.messages ?? [] }
    private var validLink: URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if thread?.older == true, let first = rawMessages.first {
                        Button("Load older messages") { load(before: first.id) }.disabled(waiting)
                    }
                    if turnIsRunning && pilot.status == nil {
                        Label("Working on your Mac…", systemImage: "clock")
                            .font(.subheadline).foregroundStyle(HeyMatePalette.secondary)
                    }
                    if let status = pilot.status {
                        Label(status, systemImage: "clock").font(.subheadline).foregroundStyle(HeyMatePalette.secondary)
                    }
                    if let problem = pilot.problem ?? pilot.notice {
                        Label(problem, systemImage: "info.circle").font(.subheadline).phoneCard()
                    }
                    if rawMessages.isEmpty {
                        Text(thread == nil && !isDraft ? "Waiting for the chat from your Mac…" : "Start the conversation.")
                            .font(.system(.title2, design: .rounded, weight: .bold)).padding(.top, 23)
                    }
                    ForEach(rawMessages) { message in
                        bubble(message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(18)
            }
            .onChange(of: rawMessages.last?.id) { _, _ in scroll.scrollTo("bottom", anchor: .bottom) }
        }
        .background(PhoneWorkspaceBackground())
        .refreshable { _ = load() }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(thread?.chat.title ?? chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isDraft {
                        Button("Refresh chat", systemImage: "arrow.clockwise") { load() }
                        Button("Continue on Mac", systemImage: "macbook.and.iphone") {
                            pilot.enqueue(.init(kind: .continueOnMac, mateID: chat.mateID, chatID: chat.id),
                                          title: "Continue on Mac")
                        }
                    }
                    if allowsMessages {
                        Button("Hand off a link", systemImage: "link") { showsLink = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Chat actions")
            }
        }
        .task(id: waiting) {
            if !requestedTranscript, thread == nil, !waiting, !isDraft { requestedTranscript = load() }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(turnIsRunning ? 4 : 12)) } catch { return }
                if !isDraft, !waiting, draft.isEmpty || turnIsRunning { load(quietly: true) }
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): attachFiles(urls)
            case .failure(let error): attachmentError = error.localizedDescription
            }
        }
        .task(id: photoItems) {
            guard !photoItems.isEmpty else { return }
            for item in photoItems {
                guard files.count < PhoneAttachment.maximumCount else { break }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "jpg"
                    addAttachment(name: "Photo \(files.count + 1).\(ext)", data: data)
                } catch { attachmentError = "Couldn’t read this photo." }
            }
            photoItems = []
        }
        .sheet(isPresented: $choosingBrain) {
            PhoneBrainPicker(options: brains, choice: $brain)
                .task { if brains.isEmpty { pilot.loadMates() } }
        }
        .sheet(isPresented: $showsLink) {
            PhoneEditorFrame(title: "Hand off a link") {
                Text("Send a link into this conversation for your mate to pick up on the Mac.")
                    .foregroundStyle(HeyMatePalette.secondary)
                field("https://…", value: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                Button("Send link", systemImage: "macbook.and.iphone") {
                    guard let validLink else { return }
                    Task {
                        if await send("Take a look at this link on my Mac: \(validLink.absoluteString)") {
                            showsLink = false
                            link = ""
                        }
                    }
                }
                .buttonStyle(PhonePrimaryButton()).disabled(waiting || turnIsRunning || validLink == nil)
            }
        }
    }

    private var composer: some View {
        Group {
            if allowsMessages {
                VStack(alignment: .leading, spacing: 8) {
                    composerOptions
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Message your mate", text: $draft, axis: .vertical)
                            .lineLimit(1...6).padding(12)
                            .background(HeyMatePalette.field, in: RoundedRectangle(cornerRadius: 17))
                        if let stoppableChat {
                            Button {
                                Task { await pilot.stopReply(stoppableChat) }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(HeyMatePalette.primary)
                                    .background(HeyMatePalette.destructive, in: Circle())
                            }
                            .accessibilityLabel("Stop reply")
                            .accessibilityIdentifier("phoneStopReply")
                            .disabled(pilot.stoppingTurnID != nil)
                        } else {
                            Button {
                                Task {
                                    if await send(draft, attachments: files) {
                                        draft = ""
                                        files = []
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up").font(.headline)
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(HeyMatePalette.glassInk)
                                    .background(HeyMatePalette.accent(accentHex), in: Circle())
                            }
                            .accessibilityLabel("Send message")
                            .disabled(!canSend)
                        }
                    }
                }
            } else {
                Text("Update this pairing on your Mac to reply here.")
                    .font(.footnote).foregroundStyle(HeyMatePalette.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12).background(HeyMatePalette.rail)
    }

    private func bubble(_ message: PhoneChatMessage) -> some View {
        HStack {
            if message.user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                Text((try? AttributedString(markdown: message.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .textSelection(.enabled)
                if let names = message.attachmentNames {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "paperclip").font(.caption)
                    }
                }
                Text(message.time.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(message.user ? HeyMatePalette.glassInk : HeyMatePalette.secondary)
            }
            .padding(13)
            .foregroundStyle(message.user ? HeyMatePalette.glassInk : HeyMatePalette.primary)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16)
                if message.user {
                    shape.fill(LinearGradient(stops: HeyMatePalette.glassStops, startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(HeyMatePalette.chatReply).overlay(shape.strokeBorder(HeyMatePalette.border))
                }
            }
            if !message.user { Spacer(minLength: 22) }
        }
    }

    @discardableResult
    private func load(before: UUID? = nil, quietly: Bool = false) -> Bool {
        guard !isDraft else { return false }
        return pilot.enqueue(.init(kind: .transcript, mateID: chat.mateID, chatID: chat.id, before: before),
                      title: "Load chat", quietly: quietly)
    }

    private var composerOptions: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 15) {
                if canAttach {
                    Button("Files", systemImage: "paperclip") { pickingFiles = true }
                        .disabled(files.count >= PhoneAttachment.maximumCount)
                    PhotosPicker(selection: $photoItems, maxSelectionCount: PhoneAttachment.maximumCount,
                                 matching: .images) { Label("Photos", systemImage: "photo") }
                        .disabled(files.count >= PhoneAttachment.maximumCount)
                }
                if canAttach || !brains.isEmpty {
                    Button(brain.flatMap { selection in brains.first { $0.id == selection.provider }?.name } ?? "Brain",
                           systemImage: "brain") { choosingBrain = true }
                }
            }
            .font(.caption.weight(.semibold))
            .disabled(pilot.uploading)
            if !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(files) { file in
                            Button {
                                files.removeAll { $0.id == file.id }
                                attachmentError = nil
                            } label: {
                                Label(file.name, systemImage: "xmark.circle").lineLimit(1)
                                    .padding(5).background(HeyMatePalette.field, in: Capsule())
                            }
                            .accessibilityLabel("Remove \(file.name)")
                        }
                    }
                }
                .font(.caption).disabled(pilot.uploading)
            }
            if let attachmentError {
                Text(attachmentError).foregroundStyle(HeyMatePalette.destructiveText).font(.caption)
            }
        }
    }

    private func attachFiles(_ urls: [URL]) {
        attachmentError = nil
        for url in urls {
            guard files.count < PhoneAttachment.maximumCount else {
                attachmentError = "Up to six attachments per message."
                break
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                let remaining = PhoneAttachment.maximumBytes - files.reduce(0) { $0 + $1.data.count }
                guard values.isRegularFile == true, let size = values.fileSize, size <= remaining else {
                    attachmentError = "Choose regular files up to 25 MB total."
                    continue
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                if let data = try handle.read(upToCount: remaining + 1) {
                    addAttachment(name: url.lastPathComponent, data: data)
                }
            } catch { attachmentError = "Couldn’t read \(url.lastPathComponent)." }
        }
    }

    private func addAttachment(name: String, data: Data) {
        guard PhoneAttachment.validName(name), !data.isEmpty, files.count < PhoneAttachment.maximumCount,
              data.count + files.reduce(0, { $0 + $1.data.count }) <= PhoneAttachment.maximumBytes else {
            attachmentError = "Choose up to six files totaling 25 MB, with valid names."
            return
        }
        files.append(.init(name: name, data: data))
    }

    private func send(_ text: String, attachments: [PhonePilotModel.LocalAttachment] = []) async -> Bool {
        await pilot.sendChat(text, chat: chat, startsNewChat: isDraft, brain: brain, files: attachments)
    }
}

struct PhoneBrainPicker: View {
    let options: [PhoneBrainOption]
    @Binding var choice: PhoneBrainChoice?
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""

    private var models: [PhoneBrainOption.Model] { options.first(where: { $0.id == provider })?.models ?? [] }
    private var efforts: [String] { models.first(where: { $0.id == model })?.efforts ?? [] }

    var body: some View {
        PhoneEditorFrame(title: "Chat brain") {
            if options.isEmpty {
                Text("Brains signed in on your Mac will appear here.").foregroundStyle(HeyMatePalette.secondary)
            }
            Picker("Brain", selection: $provider) {
                Text("Mate’s default").tag("")
                ForEach(options) { Text($0.name).tag($0.id) }
            }
            if !models.isEmpty {
                Picker("Model", selection: $model) {
                    Text("Provider default").tag("")
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
            }
            if !efforts.isEmpty {
                Picker("Effort", selection: $effort) {
                    Text("Model default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Button("Use brain") {
                choice = provider.isEmpty ? nil : .init(provider: provider,
                    model: model.isEmpty ? nil : model, effort: effort.isEmpty ? nil : effort)
                dismiss()
            }.buttonStyle(PhonePrimaryButton())
        }
        .onAppear {
            provider = choice?.provider ?? ""
            model = choice?.model ?? ""
            effort = choice?.effort ?? ""
        }
        .onChange(of: provider) { _, _ in
            if !models.contains(where: { $0.id == model }) { model = ""; effort = "" }
        }
        .onChange(of: model) { _, _ in if !efforts.contains(effort) { effort = "" } }
    }

    @Environment(\.dismiss) private var dismiss

}

struct PhoneEditorFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(21).frame(maxWidth: .infinity)
            }
            .background(PhoneWorkspaceBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct PhoneProfileEditor: View {
    @Environment(\.phoneAccentHex) private var accentHex
    let title: String
    let save: (PhoneMateProfile) -> Void
    let originalMemory: String?
    @State private var draft: PhoneMateProfile

    init(title: String, draft: PhoneMateProfile, save: @escaping (PhoneMateProfile) -> Void) {
        self.title = title
        self._draft = State(initialValue: draft)
        self.originalMemory = draft.memory
        self.save = save
    }

    var body: some View {
        PhoneEditorFrame(title: title) {
            editorLabel("Name") { field("Name", value: $draft.name) }
            editorLabel("Job") { field("What this mate does", value: $draft.job, axis: .vertical) }
            editorLabel("Personality and instructions") {
                field("How this mate should work", value: $draft.personality, axis: .vertical)
            }
            if originalMemory != nil {
                editorLabel("Memory note") {
                    field("What this mate should remember", value: Binding(
                        get: { draft.memory ?? "" }, set: { draft.memory = $0 }), axis: .vertical)
                }
            }
            Picker("Brain", selection: $draft.brain) {
                Text("Inherit from Mac").tag(String?.none)
                Text("Codex").tag(Optional("codex"))
                Text("Claude").tag(Optional("claudeCode"))
                Text("OpenCode").tag(Optional("openCode"))
                Text("Custom API").tag(Optional("customAPI"))
                Text("On this Mac").tag(Optional("onDevice"))
            }.phoneCard()
            editorLabel("Face") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        faceButton("Auto", value: "automatic")
                        ForEach(PhoneMateProfile.faces, id: \.id) { face in
                            faceButton(face.name, value: face.id)
                        }
                    }
                }
            }
            Button("Save profile") {
                draft.editsMemory = draft.memory != originalMemory
                save(draft)
            }
            .buttonStyle(PhonePrimaryButton())
            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      draft.job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func faceButton(_ name: String, value: String) -> some View {
        Button {
            draft.face = value
        } label: {
            VStack(spacing: 3) {
                PhoneMateFace(face: value == "automatic" ? nil : value, size: 49)
                Text(name).font(.caption)
            }
            .frame(width: 62).padding(.vertical, 6)
            .background(draft.face == value ? HeyMatePalette.accent(accentHex).opacity(0.30) : HeyMatePalette.surface,
                        in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
    }
}

struct PhoneRoutineEditor: View {
    let routine: PhoneRoutine?
    let mates: [PhonePilotMate]
    let save: (UUID, String, String) -> Void
    @State private var mateID: UUID?
    @State private var task: String
    @State private var schedule: String

    init(routine: PhoneRoutine?, mates: [PhonePilotMate], save: @escaping (UUID, String, String) -> Void) {
        self.routine = routine
        self.mates = mates
        self.save = save
        _mateID = State(initialValue: routine?.mateID ?? mates.first?.id)
        _task = State(initialValue: routine?.task ?? "")
        _schedule = State(initialValue: routine?.schedule ?? "")
    }

    var body: some View {
        PhoneEditorFrame(title: routine == nil ? "New routine" : "Edit routine") {
            Picker("Mate", selection: $mateID) {
                ForEach(mates) { mate in Text(mate.name).tag(Optional(mate.id)) }
            }.phoneCard().disabled(routine != nil)
            editorLabel("Task") { field("What should happen?", value: $task, axis: .vertical) }
            editorLabel("Schedule on your Mac") { field("Every weekday at 8am", value: $schedule) }
            Button("Save routine") {
                if let mateID { save(mateID, task, schedule) }
            }.buttonStyle(PhonePrimaryButton()).disabled(mateID == nil || task.isEmpty || schedule.isEmpty)
        }
    }
}

struct PhoneAnswerEditor: View {
    let question: PhoneQuestion
    let send: (String) -> Void
    @State private var answer = ""

    var body: some View {
        PhoneEditorFrame(title: question.mateName) {
            Text(question.text).font(.headline)
            ForEach(question.choices, id: \.self) { choice in Button(choice) { answer = choice } }
            field("Your answer", value: $answer, axis: .vertical)
            Button("Send answer") { send(answer) }
                .buttonStyle(PhonePrimaryButton()).disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private func field(_ prompt: String, value: Binding<String>, axis: Axis = .horizontal) -> some View {
    TextField(prompt, text: value, axis: axis).padding(13)
        .background(HeyMatePalette.surface, in: RoundedRectangle(cornerRadius: 12))
}

private func editorLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.subheadline.weight(.semibold))
        content()
    }
}
