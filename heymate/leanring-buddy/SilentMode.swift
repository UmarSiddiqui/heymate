//
//  SilentMode.swift
//  leanring-buddy
//
//  Silent mode is for using HeyMate where talking or hearing it back is not
//  an option — an office, a train, a library. While it is on:
//
//    - the Talk shortcut and the hands-free double tap open the typed
//      composer instead of the mic, so the same keys still summon HeyMate;
//    - the Dictate shortcut does nothing, since it has no typed equivalent;
//    - replies are read in the chat, never spoken;
//    - interaction sounds stay quiet.
//
//  Everything else (screen context, pointing, agents, approvals) is unchanged.
//

import Foundation

nonisolated enum SilentModePreferences {

    static let userDefaultsKey = "isSilentModeEnabled"

    /// Off by default: voice is the product's default way in.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    static let suggestionDismissedKey = "isSilentModeSuggestionDismissed"

    /// Set when the user answers "Keep talking" to the speakers offer, so
    /// someone who likes hearing replies is never asked again.
    static var isSuggestionDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: suggestionDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: suggestionDismissedKey) }
    }

    /// Whether to offer silent mode before an answer is spoken. Only when
    /// the reply is about to come out of the Mac's own speakers — through
    /// headphones nobody else hears it — and at most once per launch.
    static func shouldOfferSilentMode(
        isSilentModeEnabled: Bool,
        isSuggestionDismissed: Bool,
        hasOfferedThisSession: Bool,
        isPlayingThroughBuiltInSpeakers: Bool
    ) -> Bool {
        !isSilentModeEnabled
            && !isSuggestionDismissed
            && !hasOfferedThisSession
            && isPlayingThroughBuiltInSpeakers
    }
}

/// Wraps the real speech client so every spoken line — answers, acks,
/// reminders, failures — goes quiet in one place rather than each call site
/// remembering to check. The preference is read on every call so toggling
/// takes effect mid-session without rebuilding the client.
final class SilentModeAwareTTSClient: TTSClient {

    private let wrappedClient: any TTSClient
    private let isSilentModeEnabled: () -> Bool

    init(
        wrapping wrappedClient: any TTSClient,
        isSilentModeEnabled: @escaping () -> Bool = { SilentModePreferences.isEnabled }
    ) {
        self.wrappedClient = wrappedClient
        self.isSilentModeEnabled = isSilentModeEnabled
    }

    func speakText(_ text: String) async throws {
        guard !isSilentModeEnabled() else { return }
        try await wrappedClient.speakText(text)
    }

    var isPlaying: Bool {
        wrappedClient.isPlaying
    }

    func stopPlayback() {
        wrappedClient.stopPlayback()
    }
}
