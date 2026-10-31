#if DEBUG
import AppKit
import SwiftUI

/// Isolated native visual fixture. Starts no providers, jobs, permissions or app services.
@MainActor
enum CompanionAppearancePreview {
    private static var window: NSWindow?
    private static var previewSize: CGSize {
        CGSize(width: 740, height: CommandLine.arguments.contains("--appearance-updates") ? 700 : 560)
    }
    static func render(to path: String) throws {
        if let index = CommandLine.arguments.firstIndex(of: "--appearance-account"),
           CommandLine.arguments.indices.contains(index + 1) {
            let mode = CommandLine.arguments[index + 1]
            let account = HeyMateAccount.designPreview(verification: mode == "verify")
            let view = AccountGateView(account: account)
                .frame(width: 520, height: 550)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 550),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: URL(fileURLWithPath: path))
            return
        }
        let content: AnyView
        if CommandLine.arguments.contains("--appearance-report") {
            let update = AppearanceFixture().resultUpdate
            content = AnyView(FloatingAgentReportView(run: update.run, mateName: update.mateName).frame(width: 560, height: 420))
        } else {
            content = AnyView(AppearanceFixture().frame(width: previewSize.width, height: previewSize.height))
        }
        let renderer = ImageRenderer(content: content
            .environment(\.companionSnapshotRendering, true)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    static func exposeFloatingPanel() { window?.orderOut(nil) }
    static func restoreMainWindow() { window?.makeKeyAndOrderFront(nil) }
    static func resize(updates: Bool) { window?.setContentSize(CGSize(width: 740, height: updates ? 700 : 560)) }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: previewSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HeyMate Appearance Preview"
        window.contentView = NSHostingView(rootView: AppearanceFixture())
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

private struct AppearanceFixture: View {
    @State private var reduceMotion = false
    @State private var dark = true
    @State private var opened = false
    @State private var floatingPanel: NSPanel?
    @State private var floatingResult = ""
    @State private var focusRetainedAtCreation = false
    @State private var selectedPack = "colors"
    @State private var showUpdates = CommandLine.arguments.contains("--appearance-updates")
    @State private var updateDismissed = false
    @State private var reportOpened = false
    private let names = ["Idle", "Listening", "Thinking", "Speaking", "Needs you", "Done", "Failed"]
    private let expressions: [MateFaceExpression] = [.idle, .listening, .thinking, .speaking, .attention, .success, .failure]
    private var assets: [String] {
        if selectedPack == "colors" { return Array(MateFace.legacyAssetNames.prefix(6)) }
        if selectedPack == "portraits" { return Array(MateFace.legacyAssetNames.dropFirst(6)) }
        return MateFace.packs.first { $0.id == selectedPack }?.faces.map(\.assetName) ?? []
    }

    init() {
        let arguments = CommandLine.arguments
        let index = arguments.firstIndex(of: "--appearance-pack")
        let requested = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "colors"
        let allowed = ["colors", "signal", "margin", "instrument", "portraits", "blobatar"]
        _selectedPack = State(initialValue: allowed.contains(requested) ? requested : "colors")
    }

    private func mate(_ asset: String) -> Mate {
        Mate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: Mate.defaultName,
             job: "Preview", pinned: false, archived: false, unreadCount: 0, createdAt: .distantPast,
             updatedAt: .distantPast, memoryNote: "", faceAssetName: asset)
    }
    private func run(needsUser: Bool, result: Bool = false) -> AgentRun {
        let id = UUID(uuidString: result ? "00000000-0000-0000-0000-000000000202" :
                        needsUser ? "00000000-0000-0000-0000-000000000101" : "00000000-0000-0000-0000-000000000102")!
        var run = AgentRun.queued(id: id, title: needsUser ? "Review website changes" : "Prepare release notes",
                                  prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/appearance-preview"),
                                  executor: .openCode, origin: .sandbox)
        run.status = needsUser ? .awaitingPlanApproval : .running
        run.chatOwner = AgentChatOwner(mateID: mate(assets[0]).id,
                                      chatID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        return run
    }
    private func showFloatingCard() {
        floatingPanel?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        floatingResult = "Floating card ready. Click its Review plan card."
        let card = FloatingAgentCard(run: run(needsUser: true), mate: mate(assets[0])) {
            let remainedNonKey = floatingPanel?.isKeyWindow == false
            floatingResult = focusRetainedAtCreation && remainedNonKey
                ? "Floating card clicked. Non-key panel and creation focus verified."
                : "Floating card clicked. Focus check needs review."
            CompanionAppearancePreview.restoreMainWindow()
            floatingPanel?.orderOut(nil)
            floatingPanel?.contentView = nil
            floatingPanel = nil
        }
        .padding(8)
        .preferredColorScheme(dark ? .dark : .light)
        let previousKeyWindow = NSApplication.shared.keyWindow
        floatingPanel = FloatingAgentWindowController.previewPanel(content: card, on: screen)
        focusRetainedAtCreation = NSApplication.shared.keyWindow === previousKeyWindow
            && floatingPanel?.isKeyWindow == false
        // Make the floating panel the only visible window for native capture.
        CompanionAppearancePreview.exposeFloatingPanel()
    }

    fileprivate var resultUpdate: FloatingAgentNoticeItem {
        var completed = run(needsUser: false, result: true)
        completed.status = .succeeded
        completed.title = "Release notes ready"
        completed.finishedAt = Date(timeIntervalSince1970: 100)
        completed.privateFinalResult = "Release notes prepared. Checked the version, download name and update feed.\n\nThis report is fixture text. No provider or job executed."
        let notice = FloatingAgentNotice(id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                                         runID: completed.id, resultKey: completed.resultDeliveryKey,
                                         mateID: completed.chatOwner!.mateID, chatID: completed.chatOwner!.chatID,
                                         createdAt: completed.finishedAt!)
        return FloatingAgentNoticeItem(notice: notice, run: completed, mateName: Mate.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Mates, alive").font(DS.Fonts.title)
                Spacer()
                Button("Test floating card", action: showFloatingCard)
                Toggle("Reduce Motion preview", isOn: $reduceMotion)
                Toggle("Dark", isOn: $dark)
            }
            HStack(spacing: 8) {
                Text("Character pack").font(DS.Fonts.caption)
                ForEach(["colors", "signal", "margin", "instrument", "portraits"], id: \.self) { pack in
                    Button(pack == "portraits" ? "Original art" : pack.capitalized) { selectedPack = pack }
                        .buttonStyle(.plain)
                        .font(DS.Fonts.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(selectedPack == pack ? DS.Colors.accent : DS.Colors.surface1,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(pack) character pack")
                }
                Button("Task updates") {
                    showUpdates.toggle(); updateDismissed = false
                    CompanionAppearancePreview.resize(updates: showUpdates)
                }
                    .font(DS.Fonts.caption)
            }
            HStack(spacing: 21) {
                ForEach(expressions.indices, id: \.self) { index in
                    VStack(spacing: 12) {
                        MateFaceView(mate: mate(assets[index % assets.count]), size: 70, expression: expressions[index])
                        Text(names[index]).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active jobs").font(DS.Fonts.headline)
                    FloatingAgentStack(runs: [run(needsUser: true), run(needsUser: false)],
                                       mates: [mate(assets[0])],
                                       onOpen: { _, _ in opened = true },
                                       updates: showUpdates && !updateDismissed ? [resultUpdate] : [],
                                       onReport: { _ in reportOpened = true }, onDismiss: { _ in updateDismissed = true })
                        .frame(height: FloatingAgentPresentation.stackHeight(
                            runCount: showUpdates && !updateDismissed ? 3 : 2))
                }.frame(width: 300)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Same identity, every size").font(DS.Fonts.headline)
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach([28, 48, 96], id: \.self) { size in
                            MateFaceView(mate: mate(assets[0]), size: CGFloat(size), expression: .idle)
                        }
                    }
                    if !floatingResult.isEmpty {
                        Text(floatingResult).font(DS.Fonts.caption)
                    }
                    Text(opened ? "Card action verified. Live cards open their mate chat." : "Native fixture. No jobs execute.")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.background)
        .foregroundStyle(DS.Colors.textPrimary)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.companionMotionSuppressed, reduceMotion)
        .sheet(isPresented: $reportOpened) {
            FloatingAgentReportView(run: resultUpdate.run, mateName: resultUpdate.mateName)
        }

    }
}
#endif
