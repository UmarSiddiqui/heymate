//
//  NowPlayingMonitor.swift
//  leanring-buddy
//
//  Ambient "what is playing" for the notch, built entirely on public,
//  event-driven APIs.
//
//  macOS has no public system-wide now-playing API — MediaRemote is
//  private, and shipping a private-framework dlopen is how apps get
//  rejected and broken by point releases. Music and Spotify both post
//  distributed notifications on every playback change, and both expose a
//  scripting dictionary, so we listen for the notification (free, zero
//  polling) and read the payload it already carries. No AppleScript is
//  executed unless the notification arrives without usable metadata.
//

import AppKit
import Combine
import Foundation

@MainActor
final class NowPlayingMonitor: ObservableObject {

    /// nil when nothing is playing (or playback is paused).
    @Published private(set) var activity: NotchActivity?

    /// Full metadata for the expanded card, which has room for more than
    /// the pill's ~14 characters.
    @Published private(set) var nowPlaying: NowPlayingSnapshot?

    struct NowPlayingSnapshot: Equatable {
        let appName: String
        let title: String
        let artist: String
        let isPlaying: Bool
    }

    /// Distributed notification names each player posts on state change.
    /// Apple documents the Music one; Spotify documents theirs. Both carry
    /// a userInfo dictionary with the current track.
    private static let musicPlayerNotification = Notification.Name("com.apple.Music.playerInfo")
    private static let legacyITunesNotification = Notification.Name("com.apple.iTunes.playerInfo")
    private static let spotifyNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for name in [Self.musicPlayerNotification, Self.legacyITunesNotification, Self.spotifyNotification] {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handlePlayerNotification(notification)
                }
            }
            observers.append(observer)
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        nowPlaying = nil
        activity = nil
    }

    private func handlePlayerNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        // Music uses "Player State"; Spotify uses "Player State" too, with
        // values "Playing"/"Paused"/"Stopped" in both cases.
        let playerStateText = (userInfo["Player State"] as? String) ?? ""
        let isPlaying = playerStateText.caseInsensitiveCompare("Playing") == .orderedSame

        guard isPlaying else {
            nowPlaying = nil
            activity = nil
            return
        }

        let trackTitle = (userInfo["Name"] as? String) ?? ""
        let trackArtist = (userInfo["Artist"] as? String) ?? ""
        guard !trackTitle.isEmpty else { return }

        let sourceAppName = notification.name == Self.spotifyNotification ? "Spotify" : "Music"

        nowPlaying = NowPlayingSnapshot(
            appName: sourceAppName,
            title: trackTitle,
            artist: trackArtist,
            isPlaying: true
        )
        activity = NotchActivity(
            kind: .media,
            trailingText: Self.pillLabel(forTrackTitle: trackTitle)
        )
    }

    /// The pill's trailing slot is roughly 48 pt wide. Truncate on a word
    /// boundary where possible so "Everything In Its…" beats "Everythin…".
    nonisolated static func pillLabel(forTrackTitle trackTitle: String) -> String {
        let maximumCharacters = 14
        let trimmed = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }

        let clipped = String(trimmed.prefix(maximumCharacters))
        if let lastSpaceIndex = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpaceIndex) > 6 {
            return String(clipped[clipped.startIndex..<lastSpaceIndex]) + "…"
        }
        return clipped + "…"
    }

    // MARK: Transport

    /// Play/pause the app that produced the current snapshot. Uses the
    /// documented scripting interface, which is why this stays behind a
    /// user-initiated button rather than running automatically.
    func togglePlayPause() { sendTransportCommand("playpause") }
    func skipToNextTrack() { sendTransportCommand("next track") }
    func skipToPreviousTrack() { sendTransportCommand("previous track") }

    /// `HeyMateLocalAutomation.runAppleScript` spawns osascript and blocks
    /// until it exits, so it must never run on the main actor — a slow
    /// Apple Event would freeze the notch mid-animation.
    private func sendTransportCommand(_ command: String) {
        guard let appName = nowPlaying?.appName else { return }
        Task.detached(priority: .userInitiated) {
            _ = HeyMateLocalAutomation.runAppleScript(
                "tell application \"\(appName)\" to \(command)"
            )
        }
    }
}
