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
                occludedTopInset: 0,
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
    }

    @Test(.enabled(if: outputDirectory != nil))
    func agentBuilder() throws {
        let manager = Self.sampleManager()
        try Self.render(
            AgentBuilderSheet(companionManager: manager, initialDescription: "Every morning, read my inbox and draft replies to customers"),
            size: CGSize(width: 540, height: 360), dark: true, name: "builder-describe"
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
            size: CGSize(width: 540, height: 720), dark: true, name: "builder-review"
        )
        try Self.render(
            MateSettingsSheet(
                mate: manager.mates[0], companionManager: manager, isLastNonArchivedMate: false,
                onOpenSection: { _ in }, onSave: { _, _, _, _, _, _, _ in nil }, onDelete: {}
            ),
            size: CGSize(width: 520, height: 720), dark: true, name: "agent-edit"
        )
    }

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

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Let onAppear, tasks and animations settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])
        try data?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
