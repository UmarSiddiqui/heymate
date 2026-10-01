//
//  SilentMode.swift
//  leanring-buddy
//
//  Silent mode is for using HeyMate where talking or hearing it back is not
//  an option — an office, a train, a library. While it is on:
//
//    - the Talk shortcut and the hands-free double tap open the typed
//      composer instead of the mic, so the same keys still summon HeyMate;
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
