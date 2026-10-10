//
//  SettingsCatalog.swift
//  leanring-buddy
//
//  The shape of Settings as data: which sections exist and in what order,
//  every setting a person can search for, and the shortcut defaults that
//  "Restore defaults" goes back to.
//
//  Views read titles from here, so the word a row shows and the word search
//  matches can never drift apart. Nothing in this file touches UserDefaults
//  except `SettingsNavigationModel.reveal`, which writes the same selected-
//  section key a deep link does.
//
//  The full audit and the reasoning behind this layout are in
//  docs/settings-redesign.md.
//

import Combine
import Foundation

// MARK: - Sections

/// The Settings sections, in rail order. Raw values are persisted under
/// `storageKey` and written by deep links — never rename one.
enum DesktopSettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case voice
    case notch
    case accounts
    case agents
    case connections
    case privacy

    /// UserDefaults key holding the selected section's raw value.
    static let storageKey = "desktopSettingsSelectedTab"

    /// Raw values earlier versions wrote that no longer name a section.
    /// "advanced" was a catch-all tab; its only in-app writer was the Apps
    /// page's Composio prompt, which now lands on Connections.
    static let legacyAliases: [String: DesktopSettingsTab] = [
        "advanced": .connections
    ]

    /// The section a stored or deep-linked raw value means. Unknown values
    /// fall back to General rather than an empty pane.
    static func resolve(_ rawValue: String) -> DesktopSettingsTab {
        DesktopSettingsTab(rawValue: rawValue) ?? legacyAliases[rawValue] ?? .general
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .voice: return "Talk & Voice"
        case .notch: return "Notch"
        case .accounts: return "AI & Accounts"
        case .agents: return "Agents & Control"
        case .connections: return "Connections"
        case .privacy: return "Privacy & Data"
        }
    }

    /// The one line under the page title: what this section is for.
    var subtitle: String {
        switch self {
        case .general:
            return "How HeyMate looks, starts, and stays up to date."
        case .shortcuts:
            return "The keys that summon HeyMate from anywhere on your Mac."
        case .voice:
            return "How HeyMate listens to you and how it sounds."
        case .notch:
            return "Small things that live around the camera. Each is off until you turn it on."
        case .accounts:
            return "Which AI answers you, and how hard it thinks."
        case .agents:
            return "Jobs that work on their own, and what HeyMate may do on this Mac."
        case .connections:
            return "The apps and services HeyMate can reach for you."
        case .privacy:
            return "What HeyMate sees, what it keeps, and how to erase it."
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .voice: return "waveform"
        case .notch: return "rectangle.topthird.inset.filled"
        case .accounts: return "sparkles"
        case .agents: return "cursorarrow.click.2"
        case .connections: return "app.connected.to.app.below.fill"
        case .privacy: return "hand.raised"
        }
    }

    var group: DesktopSettingsTabGroup {
        switch self {
        case .general, .shortcuts, .voice, .notch: return .heyMate
        case .accounts, .agents, .connections: return .intelligence
        case .privacy: return .privacy
        }
    }
}

/// Headings in the section rail.
enum DesktopSettingsTabGroup: String, CaseIterable, Identifiable {
    case heyMate
    case intelligence
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heyMate: return "HeyMate"
        case .intelligence: return "Intelligence"
        case .privacy: return "Privacy"
        }
    }

    var tabs: [DesktopSettingsTab] {
        DesktopSettingsTab.allCases.filter { $0.group == self }
    }
}

// MARK: - Searchable settings

/// Every setting search can find. The raw value doubles as the row's scroll
/// anchor, so it must be unique (an enum guarantees that).
enum SettingsItem: String, CaseIterable, Identifiable {
    // General
    case accentColor
    case launchAtLogin
    case showInDock
    case noNotchPlacement
    case cursorCompanion
    case softwareUpdates
    case helpAndFeedback
    case replayIntroduction

    // Shortcuts
    case talkShortcut
    case chatShortcut
    case dictateShortcut
    case regionShortcut
    case doubleTapText
    case doubleTapHandsFree
    case restoreShortcuts

    // Talk & Voice
    case silentMode
    case dictationMode
    case focusedWindow
    case interactionSounds
    case microphone
    case listenProvider
    case speakProvider
    case onDeviceVoice
    case macVoice
    case elevenLabsKey
    case elevenLabsVoice

    // Notch
    case microApps
    case hoverOpensCard
    case notchContent

    // AI
    case yourAI
    case model
    case effort
    case voiceChat
    case otherEngines
    case helperApps

    // Agents & Control
    case agentSignIn
    case projectFolder
    case computerControl
    case backgroundAppControl
    case behaviorContract

    // Connections
    case connectedApps
    case composioKey
    case google

    // Privacy & Data
    case excludedApps
    case screenRecordings
    case saveChats
    case memories
    case whatLeavesThisMac
    case eraseData

    var id: String { rawValue }

    var tab: DesktopSettingsTab {
        switch self {
        case .accentColor, .launchAtLogin, .showInDock, .noNotchPlacement,
             .cursorCompanion, .softwareUpdates, .helpAndFeedback, .replayIntroduction:
            return .general
        case .talkShortcut, .chatShortcut, .dictateShortcut, .regionShortcut,
             .doubleTapText, .doubleTapHandsFree, .restoreShortcuts:
            return .shortcuts
        case .silentMode, .dictationMode, .focusedWindow, .interactionSounds,
             .microphone, .listenProvider, .speakProvider, .onDeviceVoice,
             .macVoice, .elevenLabsKey, .elevenLabsVoice:
            return .voice
        case .microApps, .hoverOpensCard, .notchContent:
            return .notch
        case .yourAI, .model, .effort, .voiceChat, .otherEngines, .helperApps:
            return .accounts
        case .agentSignIn, .projectFolder, .computerControl, .backgroundAppControl, .behaviorContract:
            return .agents
        case .connectedApps, .composioKey, .google:
            return .connections
        case .excludedApps, .screenRecordings, .saveChats, .memories, .whatLeavesThisMac, .eraseData:
            return .privacy
        }
    }

    /// The row's title, word for word.
    var title: String {
        switch self {
        case .accentColor: return "Accent color"
        case .launchAtLogin: return "Open at login"
        case .showInDock: return "Show in Dock"
        case .noNotchPlacement: return "Without a notch"
        case .cursorCompanion: return "Cursor companion"
        case .softwareUpdates: return "Software updates"
        case .helpAndFeedback: return "Help and feedback"
        case .replayIntroduction: return "Introduction"
        case .talkShortcut: return "Talk"
        case .chatShortcut: return "Chat"
        case .dictateShortcut: return "Dictate"
        case .regionShortcut: return "Region select"
        case .doubleTapText: return "Typed ask"
        case .doubleTapHandsFree: return "Hands-free talk"
        case .restoreShortcuts: return "Restore default shortcuts"
        case .silentMode: return "Silent mode"
        case .dictationMode: return "Dictation style"
        case .focusedWindow: return "Look at the front window only"
        case .interactionSounds: return "Interaction sounds"
        case .microphone: return "Microphone"
        case .listenProvider: return "Listen with"
        case .speakProvider: return "Speak with"
        case .onDeviceVoice: return "On-device voice"
        case .macVoice: return "Mac voice"
        case .elevenLabsKey: return "ElevenLabs API key"
        case .elevenLabsVoice: return "ElevenLabs voice"
        case .microApps: return "Micro-apps"
        case .hoverOpensCard: return "Open the card on hover"
        case .notchContent: return "In the notch now"
        case .yourAI: return "Your AI"
        case .model: return "Model"
        case .effort: return "Effort"
        case .voiceChat: return "Voice chat"
        case .otherEngines: return "Other engines"
        case .helperApps: return "Keep helper apps updated"
        case .agentSignIn: return "Agent sign-in"
        case .projectFolder: return "Project folder"
        case .computerControl: return "Let HeyMate use this Mac"
        case .backgroundAppControl: return "Background app control"
        case .behaviorContract: return "Honesty and safety rules"
        case .connectedApps: return "Connected apps"
        case .composioKey: return "Composio API key"
        case .google: return "Google"
        case .excludedApps: return "Never capture these apps"
        case .screenRecordings: return "Show in screen recordings"
        case .saveChats: return "Save chats on this Mac"
        case .memories: return "Memories"
        case .whatLeavesThisMac: return "What leaves this Mac"
        case .eraseData: return "Erase HeyMate data"
        }
    }

    /// Other words a person might type for this setting. Not shown.
    var keywords: String {
        switch self {
        case .accentColor: return "theme colour tint swatch appearance look"
        case .launchAtLogin: return "launch startup start login item boot"
        case .showInDock: return "dock icon menu bar app switcher"
        case .noNotchPlacement: return "fake notch menu bar external display monitor"
        case .cursorCompanion: return "pointer follow buddy overlay"
        case .softwareUpdates: return "update version check automatic sparkle release"
        case .helpAndFeedback: return "bug report feature request email support issue permissions github"
        case .replayIntroduction: return "onboarding tutorial welcome replay intro"
        case .talkShortcut: return "push to talk hold key hotkey ask screen"
        case .chatShortcut: return "notch chat type hotkey"
        case .dictateShortcut: return "dictation transcribe type hotkey"
        case .regionShortcut: return "circle area spatial selection screen hotkey"
        case .doubleTapText: return "double tap control text box"
        case .doubleTapHandsFree: return "double tap hands free voice activity"
        case .restoreShortcuts: return "reset defaults keys"
        case .silentMode: return "quiet mute public work type no voice"
        case .dictationMode: return "smart literal dictation mode"
        case .focusedWindow: return "context screen capture focused window front app"
        case .interactionSounds: return "clicks chime blip sound effects feedback audio"
        case .microphone: return "mic input device audio headset airpods"
        case .listenProvider: return "speech recognition transcription parakeet apple elevenlabs stt"
        case .speakProvider: return "text to speech tts kokoro elevenlabs reply voice"
        case .onDeviceVoice: return "download offline private parakeet kokoro model local"
        case .macVoice: return "system voice premium spoken content"
        case .elevenLabsKey: return "elevenlabs api key cloud voice"
        case .elevenLabsVoice: return "elevenlabs voice id clone"
        case .microApps: return "shelf timer clipboard battery now playing calendar camera"
        case .hoverOpensCard: return "hover peek notch card expand"
        case .notchContent: return "file shelf clipboard history timer next event"
        case .yourAI: return "claude chatgpt openai anthropic plan subscription sign in apple intelligence brain engine"
        case .model: return "claude chatgpt gpt sonnet opus haiku model"
        case .effort: return "reasoning thinking effort"
        case .voiceChat: return "voice conversation talk"
        case .otherEngines: return "opencode custom api server anthropic compatible endpoint"
        case .helperApps: return "cli codex claude opencode update helper"
        case .agentSignIn: return "jobs terminal sign out account login"
        case .projectFolder: return "sandbox projects folder finder"
        case .computerControl: return "computer use accessibility automation click type control"
        case .backgroundAppControl: return "cua driver background"
        case .behaviorContract: return "behavior contract rules honesty safety edit"
        case .connectedApps: return "gmail slack calendar notion connectors integrations apps"
        case .composioKey: return "composio api key web apps"
        case .google: return "gogcli gmail drive calendar google"
        case .excludedApps: return "exclude bundle id password manager screenshot capture block"
        case .screenRecordings: return "screenshot share screen hide recording zoom"
        case .saveChats: return "chat history conversations remember save"
        case .memories: return "memory forget remember"
        case .whatLeavesThisMac: return "cloud data privacy sent"
        case .eraseData: return "delete reset wipe erase remove all data"
        }
    }
}

// MARK: - Search

enum SettingsSearch {
    /// Folds case and diacritics so "Micro" finds "micro-apps" and "resume"
    /// would find "résumé".
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Settings matching every word of `query`, best match first: titles
    /// that start with the query, then titles containing it, then matches
    /// only in a synonym or the section name. Ties keep catalog order.
    static func results(for query: String) -> [SettingsItem] {
        let words = normalized(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        let whole = words.joined(separator: " ")
        var scored: [(item: SettingsItem, score: Int, order: Int)] = []

        for (order, item) in SettingsItem.allCases.enumerated() {
            let title = normalized(item.title)
            let haystack = [title, normalized(item.keywords), normalized(item.tab.title)]
                .joined(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }

            let score: Int
            if title.hasPrefix(whole) {
                score = 0
            } else if title.contains(whole) {
                score = 1
            } else if words.allSatisfy({ title.contains($0) }) {
                score = 2
            } else {
                score = 3
            }
            scored.append((item, score, order))
        }

        return scored
            .sorted { ($0.score, $0.order) < ($1.score, $1.order) }
            .map(\.item)
    }
}

// MARK: - Navigation

/// Search text and "take me to this row" requests, shared by the section
/// rail and the page. The selected section itself stays in UserDefaults
/// (`DesktopSettingsTab.storageKey`) so deep links keep working.
@MainActor
final class SettingsNavigationModel: ObservableObject {
    struct RevealRequest: Equatable {
        let item: SettingsItem
        let id = UUID()
    }

    @Published var searchQuery = ""
    /// A row a page should scroll to. Cleared once a page has scrolled.
    @Published private(set) var revealRequest: RevealRequest?
    /// The row currently washed with the reveal highlight.
    @Published private(set) var highlightedItem: SettingsItem?

    private var highlightClearTask: Task<Void, Never>?

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchResults: [SettingsItem] {
        SettingsSearch.results(for: searchQuery)
    }

    /// Opens the item's section and asks that page to scroll to it.
    func reveal(_ item: SettingsItem) {
        UserDefaults.standard.set(item.tab.rawValue, forKey: DesktopSettingsTab.storageKey)
        searchQuery = ""
        revealRequest = RevealRequest(item: item)
    }

    /// Called by the page once it has scrolled; starts the highlight.
    func didReveal(_ request: RevealRequest) {
        guard revealRequest == request else { return }
        revealRequest = nil
        highlightedItem = request.item
        highlightClearTask?.cancel()
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DS.SettingsLayout.revealHighlightSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlightedItem = nil
        }
    }
}

// MARK: - Shortcut defaults

/// The four hold-to-talk roles, their shipped defaults, and which of them
/// currently share a combo.
enum SettingsShortcutRole: String, CaseIterable, Identifiable {
    case talk
    case chat
    case dictate
    case region

    var id: String { rawValue }

    /// Must match the fallbacks in `BuddyPushToTalkShortcut`.
    var defaultOption: BuddyPushToTalkShortcut.ShortcutOption {
        switch self {
        case .talk: return .controlOption
        case .chat: return .controlCommand
        case .dictate: return .shiftFunction
        case .region: return .shiftControl
        }
    }

    var item: SettingsItem {
        switch self {
        case .talk: return .talkShortcut
        case .chat: return .chatShortcut
        case .dictate: return .dictateShortcut
        case .region: return .regionShortcut
        }
    }

    /// Roles whose combo is also assigned to another role. Two roles on one
    /// combo means whichever press started first wins, so the UI warns.
    static func conflictingRoles(
        in assignments: [SettingsShortcutRole: BuddyPushToTalkShortcut.ShortcutOption]
    ) -> Set<SettingsShortcutRole> {
        var rolesByOption: [BuddyPushToTalkShortcut.ShortcutOption: [SettingsShortcutRole]] = [:]
        for role in allCases {
            guard let option = assignments[role] else { continue }
            rolesByOption[option, default: []].append(role)
        }
        return Set(rolesByOption.values.filter { $0.count > 1 }.flatMap { $0 })
    }
}

/// Shipped defaults for the double-tap channels. Must match the fallbacks in
/// `ModifierDoubleTapPreferences`.
enum SettingsDoubleTapDefaults {
    static let isTextEnabled = false
    static let textShortcut: ModifierDoubleTapShortcut = .control
    static let isHandsFreeEnabled = false
    static let handsFreeShortcut: ModifierDoubleTapShortcut = .controlFunction
}
