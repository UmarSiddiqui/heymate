//
//  UISnapshotTests.swift
//  HeyMateTests
//
//  Renders key screens to PNG for design review. Opt-in: runs only when
//  HEYMATE_SNAPSHOT_DIR is set (pass it as TEST_RUNNER_HEYMATE_SNAPSHOT_DIR
//  to xcodebuild), so normal test runs skip it.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HeyMate

@MainActor
struct UISnapshotTests {

    nonisolated private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["HEYMATE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// The drive consent card with the goal sentence a real Talk turn wrote.
    @Test(.enabled(if: outputDirectory != nil))
    func driveConsentCard() throws {
        try Self.render(
            DriveTakeOverConsentCard(
                goal: "The current calculation is cleared and 998633 is entered.",
                applicationName: "Calculator",
                origin: "talk",
                topInset: 32,
                onDecline: {},
                onAccept: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.4)),
            size: CGSize(width: 720, height: 140),
            dark: true,
            name: "drive-consent"
        )
    }

    /// The notch's one-at-a-time permission ask with two switches off.
    @Test(.enabled(if: outputDirectory != nil))
    func notchPermissionFlow() throws {
        let guide = PermissionGuide { permission in
            permission != .accessibility && permission != .screenRecording
        }
        try Self.render(
            NotchPermissionFlow(guide: guide, openChecklist: {})
                .padding(16)
                .frame(width: 420)
                .background(Color.black),
            size: CGSize(width: 420, height: 110),
            dark: true,
            name: "notch-permission-flow"
        )
    }

    /// The welcome tour's interview: mid-conversation, thinking, and done
    /// with the mates it made; plus the closing page.
    @Test(.enabled(if: outputDirectory != nil))
    func onboardingInterview() throws {
        let manager = CompanionManager()
        let now = Date()
        let made = [
            ("Launch Desk", "Plans each HeyMate release and drafts the changelog from your commits."),
            ("Bug Net", "Triages crash reports and feedback into a short fix list every morning."),
            ("Reply Scout", "Finds people asking for a notch assistant and drafts replies for you.")
        ]
        manager.mates = made.map { name, job in
            var mate = Mate(id: UUID(), name: name, job: job, pinned: false, archived: false, unreadCount: 0,
                            createdAt: now, updatedAt: now, memoryNote: "")
            mate.faceAssetName = BlobatarCharacter.automaticToken
            return mate
        }
        OnDeviceVoiceModelStore.shared.refreshInstalledState()
        let tour = OnboardingTour(companionManager: manager, restart: true)
        let firstJobs = [
            "Launch Desk": "I'll draft release notes for your next build from this week's commits.",
            "Bug Net": "I'll sort your open crash reports into a top five fix list.",
            "Reply Scout": "I'll find ten recent posts asking for a Mac notch assistant, with links.",
        ]
        let opening = [
            OnboardingInterviewLine(speaker: .heyMate, text: "So, Umar. I'm curious about you."),
            OnboardingInterviewLine(speaker: .heyMate, text: OnboardingInterview.openingQuestion),
        ]
        let middle = opening + [
            OnboardingInterviewLine(speaker: .user, text: "Building a Mac app that lives in the notch"),
            OnboardingInterviewLine(speaker: .heyMate, text: "Love that."),
            OnboardingInterviewLine(speaker: .heyMate, text: "What would make this month a win for it?"),
        ]
        let finished = middle + [
            OnboardingInterviewLine(speaker: .user, text: "Ship the launch"),
            OnboardingInterviewLine(speaker: .heyMate, text: "Big month."),
            OnboardingInterviewLine(speaker: .heyMate, text: "Which apps are you in all day?"),
            OnboardingInterviewLine(speaker: .user, text: "Xcode and Terminal"),
            OnboardingInterviewLine(speaker: .heyMate, text: "A builder's desk."),
            OnboardingInterviewLine(speaker: .heyMate, text: "You're shipping a notch app and want this launch to land."),
            OnboardingInterviewLine(speaker: .heyMate, text: "I made you 3 mates for that. They're waiting in your sidebar."),
        ]
        let states: [(String, () -> Void)] = [
            ("start", { tour.stageForSnapshot(step: .interview, lines: opening, suggestions: OnboardingInterview.openingSuggestions, name: "Umar") }),
            ("middle", { tour.stageForSnapshot(step: .interview, lines: middle, suggestions: ["Ship the launch", "First 100 users", "Fix the bugs"], name: "Umar") }),
            ("thinking", { tour.stageForSnapshot(step: .interview, lines: opening + [middle[2]], thinking: true, name: "Umar") }),
            ("done", { tour.stageForSnapshot(step: .interview, lines: finished, done: true, mateNames: made.map(\.0), name: "Umar") }),
            ("reveal", { tour.stageForSnapshot(step: .reveal, done: true, mateNames: made.map(\.0), name: "Umar") }),
            ("talk", { tour.stageForSnapshot(step: .talk, name: "Umar", speech: "This is how you talk to me. Hold the keys, tell me your name, then let go.") }),
            ("talk-done", { tour.stageForSnapshot(step: .talk, done: true, name: "Umar", speech: "Nice to meet you, Umar!", status: "Hi, Umar.") }),
            ("point", { tour.stageForSnapshot(step: .point, done: true, answer: "You've got Xcode open on OnboardingWindow.swift. The interesting bit is the stage frame: it's where my face lives now.") }),
            ("voice", { tour.stageForSnapshot(step: .voice, done: true) }),
            ("hello", { tour.stageForSnapshot(step: .hello, done: true) }),
            ("permissions", { tour.stageForSnapshot(step: .permissions) }),
            ("ai", { tour.stageForSnapshot(step: .ai) }),
            ("showMe", { tour.stageForSnapshot(step: .showMe, speech: "Now let me show you what I can do. Hold the keys and say: show me how you'd help me.") }),
            ("kickoff", { tour.stageForSnapshot(step: .kickoff, mateNames: made.map(\.0), jobs: firstJobs) }),
            ("kickoff-decided", { tour.stageForSnapshot(step: .kickoff, done: true, mateNames: made.map(\.0), status: "Working. Results land in each mate's chat.", jobs: firstJobs, decisions: ["Launch Desk": true, "Bug Net": false, "Reply Scout": true]) }),
            ("firstTask", { tour.stageForSnapshot(step: .kickoff) }),
        ]
        for (name, stage) in states {
            stage()
            try Self.render(OnboardingRootView(tour: tour), size: OnboardingWindowController.contentSize, dark: true,
                            name: "onboarding-\(name)", settle: name == "hello" ? 4.5 : 1.2)
        }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func mateHome() throws {
        let manager = Self.sampleManager()
        for drawer in [false, true] {
            for dark in [true, false] {
                try Self.render(
                    MateHomeView(
                        companionManager: manager,
                        isCompactLayout: false,
                        onOpenSection: { _ in },
                        startsWithDrawerOpen: drawer
                    ),
                    size: CGSize(width: 1180, height: 740),
                    dark: dark,
                    name: "home\(drawer ? "-drawer" : "")-\(dark ? "dark" : "light")"
                )
            }
        }
    }

    /// A silent-mode reply carrying an OpenUI block, in the reply bubble.
    @Test(.enabled(if: outputDirectory != nil))
    func richReply() throws {
        let manager = Self.sampleManager()
        let reply = """
        **Pro** is the better fit: you're past the free limits on two of three counts, and yearly billing saves 17%.
        ```openui
        root = Stack([usage, plans, note, next])
        usage = Row([Stat("Seats", "8", "+3 this month"), Stat("Storage", "41 GB", "of 50 GB"), Stat("API calls", "1.2M", "-4% vs Sept")])
        plans = Table(["Plan", "Monthly", "Yearly", "Seats"], [["Free", "$0", "$0", "3"], ["Pro", "$12", "$120", "25"], ["Team", "$20", "$200", "Unlimited"]])
        note = Callout("Storage hits the cap in about 9 days at this pace.", "warning", "Heads up")
        next = Row([Button("Switch to Pro", @ToAssistant("switch me to the pro plan"), "primary"), Button("Compare features", @ToAssistant("compare pro and team features")), Link("Pricing page", "https://example.com/pricing")])
        ```
        ```bash
        heymate plan switch --to pro --yearly
        ```
        """
        let now = Date()
        manager.currentChat.messages = [
            ChatMessage(id: UUID(), role: .user, text: "Which plan should we be on?", createdAt: now.addingTimeInterval(-120)),
            ChatMessage(id: UUID(), role: .assistant, text: reply, createdAt: now.addingTimeInterval(-110))
        ]
        try Self.render(
            MateHomeView(companionManager: manager, isCompactLayout: false, onOpenSection: { _ in }),
            size: CGSize(width: 1180, height: 900),
            dark: true,
            name: "rich-reply-dark"
        )
    }

    @Test(.enabled(if: outputDirectory != nil))
    func settings() throws {
        let manager = Self.sampleManager()
        for tab in DesktopSettingsTab.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: DesktopSettingsTab.storageKey)
            try Self.render(
                DesktopSettingsView(companionManager: manager),
                size: CGSize(width: 1000, height: 720),
                dark: true,
                name: "settings-\(tab.rawValue)"
            )
        }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func voicePicker() throws {
        try Self.render(
            VStack {
                SettingsSection("Voices") {
                    SpeechSpeedRow().settingsRowInsets()
                    SettingsDivider()
                    OnDeviceVoiceGrid().settingsRowInsets()
                }
                Spacer()
            }
            .padding(24)
            .background(DS.Colors.background),
            size: CGSize(width: 900, height: 420),
            dark: true,
            name: "voice-picker"
        )
    }

    @Test(.enabled(if: outputDirectory != nil))
    func attachedPanel() throws {
        let manager = Self.sampleManager()
        try Self.render(
            ZStack(alignment: .top) {
                Color(white: 0.35)
                Color.black.frame(width: 200, height: 32)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                AttachedDesktopChrome(
                    neckWidth: 200, neckHeight: 42, cornerRadius: 22,
                    onClose: {}, onDetach: {}
                ) {
                    MateHomeView(companionManager: manager, isCompactLayout: false, onOpenSection: { _ in })
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            },
            size: CGSize(width: 1240, height: 800),
            dark: true,
            name: "attached-panel"
        )
    }

    @Test(.enabled(if: outputDirectory != nil))
    func notchMatesPeek() throws {
        let manager = Self.sampleManager()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Outreach\n\nNick Saraev — draft ready\nLeon van Zyl — draft ready".write(
            to: folder.appendingPathComponent("outreach.md"), atomically: true, encoding: .utf8)
        try "Channel,Email\nIndyDevDan,yes\nAI Anytime,yes".write(
            to: folder.appendingPathComponent("leads.csv"), atomically: true, encoding: .utf8)
        manager.mates[0].folderPath = folder.path
        try Self.render(
            NotchMatesPeek(companionManager: manager)
                .padding(16)
                .background(Color.black),
            size: CGSize(width: 380, height: 260),
            dark: true,
            name: "notch-mates-peek"
        )
    }

    @Test(.enabled(if: outputDirectory != nil))
    func integrationsPage() throws {
        let manager = Self.sampleManager()
        try Self.render(
            DesktopConnectorsView(
                companionManager: manager,
                store: manager.connectorStore,
                runtime: manager.connectorRuntime,
                composioConnections: manager.composioConnections,
                composioToolkitDirectory: manager.composioToolkitDirectory
            )
            .background(DS.Colors.background),
            size: CGSize(width: 1000, height: 720),
            dark: true,
            name: "integrations"
        )
    }

    @Test(.enabled(if: outputDirectory != nil))
    func notchHome() throws {
        let manager = Self.sampleManager()
        let size = CGSize(width: NotchLayoutMath.expandedWidth, height: NotchLayoutMath.expandedHeight + 38)
        let transition = NotchSurfaceTransitionModel()
        transition.showWithoutAnimation()
        try Self.render(
            NotchExpandedView(
                companionManager: manager,
                occludedTopInset: 38,
                layoutSize: size,
                hardwareNotchWidth: 200,
                transitionModel: transition,
                onClose: {}
            )
            .background(Color.black),
            size: size,
            dark: true,
            name: "notch-home"
        )
        try Self.render(
            NotchUsageView(companionManager: manager)
                .background(Color.black),
            size: CGSize(
                width: NotchLayoutMath.expandedWidth,
                height: NotchLayoutMath.expandedHeight - NotchControlMetrics.bottomBarHeight
            ),
            dark: true,
            name: "notch-usage"
        )
    }

    /// The expanded card as it hangs from a 14″ notch: Home and Usage at
    /// rest, plus three frames of the open morph, all over a grey desktop
    /// and menu bar so the silhouette (shoulders, corners) is visible.
    @Test(.enabled(if: outputDirectory != nil))
    func notchSilhouette() throws {
        let manager = Self.sampleManager()
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let inset: CGFloat = 32
        let auxLeft: CGFloat = 665
        let auxRight: CGFloat = 850
        let card = try #require(NotchLayoutMath.expandedFrame(
            screenFrame: screen, topSafeAreaInset: inset,
            auxiliaryTopLeftMaxX: auxLeft, auxiliaryTopRightMinX: auxRight
        ))
        let pill = try #require(NotchLayoutMath.pillFrame(
            screenFrame: screen, topSafeAreaInset: inset,
            auxiliaryTopLeftMaxX: auxLeft, auxiliaryTopRightMinX: auxRight
        ))
        let canvas = CGSize(width: card.width + 120, height: card.height + 50)

        func frame(
            _ windowSize: CGSize,
            tab: NotchExpandedTab,
            transition: NotchSurfaceTransitionModel
        ) -> some View {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(white: 0.46), Color(white: 0.30)],
                    startPoint: .top, endPoint: .bottom
                )
                Color(white: 0.58).frame(height: inset)
                    .frame(maxHeight: .infinity, alignment: .top)
                NotchExpandedView(
                    companionManager: manager,
                    occludedTopInset: inset,
                    layoutSize: card.size,
                    hardwareNotchWidth: auxRight - auxLeft,
                    transitionModel: transition,
                    initialTab: tab,
                    onClose: {}
                )
                .frame(width: windowSize.width, height: windowSize.height)
            }
        }

        for tab in NotchExpandedTab.allCases {
            let transition = NotchSurfaceTransitionModel()
            transition.showWithoutAnimation()
            try Self.render(
                frame(card.size, tab: tab, transition: transition),
                size: canvas, dark: true, name: "notch-\(tab == .home ? "home" : "tools")-silhouette"
            )
        }

        for percent in [30, 60, 90] {
            let linear = CGFloat(percent) / 100
            let transition = NotchSurfaceTransitionModel()
            transition.prepare()
            transition.present()
            transition.updateMorph(easedProgress: NotchLayoutMath.swooshEase(linear), linearProgress: linear)
            let morph = NotchLayoutMath.interpolatedRect(
                from: pill, to: card,
                widthProgress: NotchLayoutMath.swooshEase(linear),
                heightProgress: NotchLayoutMath.liquidOpenHeightProgress(linearProgress: linear)
            )
            try Self.render(
                frame(morph.size, tab: .home, transition: transition),
                size: canvas, dark: true, name: "notch-open-\(percent)"
            )
        }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func agentBuilder() throws {
        let manager = Self.sampleManager()
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialDescription: "Every morning, read my inbox and draft replies to customers"),
            size: CGSize(width: 540, height: 640), dark: true, name: "builder-describe"
        )
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialRecipe: AgentRecipeCatalog.all[0]),
            size: CGSize(width: 540, height: 820), dark: true, name: "builder-recipe-review"
        )
        let draft = AgentDraft(
            name: "Inbox Ivy",
            role: "Draft replies to customer email every morning",
            personality: "Warm and brief. Writes like you, not like a help desk.",
            howItWorks: [
                "Read new customer email each morning before 9",
                "Save drafts in Gmail, never send them",
                "Lead the summary with anything urgent or angry"
            ],
            asksFirst: ["Sending any email", "Offering refunds or discounts"],
            firstTask: "Draft replies to today's customer emails and tell me which ones need me",
            integrations: ["Gmail", "Notion"]
        )
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialDraft: draft),
            size: CGSize(width: 540, height: 780), dark: true, name: "builder-review"
        )
        try Self.render(
            MateSettingsSheet(
                mate: manager.mates[0], companionManager: manager,
                onOpenSection: { _ in }, onSave: { _, _, _, _ in nil }, onDelete: {}
            ),
            size: CGSize(width: 520, height: 720), dark: true, name: "agent-edit"
        )
    }

    /// Renders for the website, in the app's matte dark look. Sample data only; nothing from this Mac.
    @Test(.enabled(if: outputDirectory != nil))
    func websiteShots() throws {
        let manager = Self.sampleManager()
        // Made-up people only: these images are published.
        manager.mates[0].name = "Inbox Ivy"
        manager.mates[0].job = "Draft replies to customer email every morning"
        manager.mates[0].soul = "Warm and brief. Writes like you, not like a help desk."
        // The site shows the app's live Blobatar cast, same looks as the landing page.
        for (index, face) in ["BlobatarTide", "BlobatarSun", "BlobatarMint"].enumerated() {
            manager.mates[index].faceAssetName = face
        }
        var chat = manager.savedChats[0]
        chat.messages[0].text = "Draft replies to today's customer emails and tell me which ones need me."
        chat.messages[1].text = "Drafted **6 replies** and saved them in Gmail. Nothing was sent.\n\nTwo need you: **Dana** wants a refund on an annual plan, and **Jules** is asking about a late order. I left both as drafts with a suggested answer."
        manager.savedChats[0] = chat
        manager.currentChat = chat
        try Self.render(
            MateHomeView(companionManager: manager, isCompactLayout: false, onOpenSection: { _ in }),
            size: CGSize(width: 1180, height: 740), dark: true, name: "site-agent-chat"
        )
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialDescription: "Every morning, read my inbox and draft replies to customers"),
            size: CGSize(width: 540, height: 640), dark: true, name: "site-builder-describe"
        )
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialDraft: Self.sampleDraft),
            size: CGSize(width: 540, height: 760), dark: true, name: "site-builder-review"
        )
        try Self.render(
            DesktopConnectorsView(
                companionManager: manager,
                store: manager.connectorStore,
                runtime: manager.connectorRuntime,
                composioConnections: manager.composioConnections,
                composioToolkitDirectory: manager.composioToolkitDirectory
            )
            .background(DS.Colors.background),
            size: CGSize(width: 1000, height: 640), dark: true, name: "site-integrations", settle: 4
        )
    }

    static let sampleDraft = AgentDraft(
        name: "Inbox Ivy",
        role: "Draft replies to customer email every morning",
        personality: "Warm and brief. Writes like you, not like a help desk.",
        howItWorks: [
            "Read new customer email each morning before 9",
            "Save drafts in Gmail, never send them",
            "Lead the summary with anything urgent or angry"
        ],
        asksFirst: ["Sending any email", "Offering refunds or discounts"],
        firstTask: "Draft replies to today's customer emails and tell me which ones need me",
        integrations: ["Gmail", "Notion"]
    )

    // MARK: Fixtures

    static func sampleManager() -> CompanionManager {
        let manager = CompanionManager()
        let now = Date()
        func mate(_ name: String, _ job: String, minutesAgo: Double, soul: String = "") -> Mate {
            Mate(
                id: UUID(), name: name, job: job, pinned: false, archived: false, unreadCount: 0,
                createdAt: now, updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                memoryNote: "", soul: soul
            )
        }
        var scout = mate("Launch Scout", "Outreach researcher", minutesAgo: 4,
                         soul: "Finds the creators and communities who could put HeyMate in front of developers.")
        scout.unreadCount = 1
        let radar = mate("Market Radar", "Tracks notch-app competitors", minutesAgo: 30)
        let builds = mate("Builds", "Coding agent for my side projects", minutesAgo: 60 * 26)
        manager.mates = [scout, radar, builds]
        manager.activeMateID = scout.id

        func session(_ owner: Mate, _ lines: [(ChatRole, String)], minutesAgo: Double) -> ChatSession {
            let at = now.addingTimeInterval(-minutesAgo * 60)
            return ChatSession(
                id: UUID(), title: "Chat", createdAt: at, updatedAt: at,
                messages: lines.enumerated().map { index, line in
                    ChatMessage(id: UUID(), role: line.0, text: line.1, createdAt: at.addingTimeInterval(Double(index)))
                },
                mateID: owner.id
            )
        }
        let scoutChat = session(scout, [
            (.user, "Find three YouTubers who'd care about a notch assistant and draft outreach."),
            (.assistant, "Drafted and verified three personalized emails for **Nick Saraev**, **Leon van Zyl**, and **AI Anytime**.\n\nThe other leads have no public email; I can draft pitches for their socials next.")
        ], minutesAgo: 4)
        manager.savedChats = [
            scoutChat,
            session(radar, [(.assistant, "Updated the baseline with the latest competitor pricing.")], minutesAgo: 30),
            session(builds, [(.assistant, "Shipped the dark mode toggle. Undo snapshot is ready.")], minutesAgo: 60 * 26)
        ]
        manager.currentChat = scoutChat
        return manager
    }

    // MARK: Rendering

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String, settle: TimeInterval = 0.8) throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Let onAppear, tasks and animations settle.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])
        try data?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
