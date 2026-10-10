//
//  NowPlayingMonitor.swift
//  HeyMate
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
//  Album art is the one exception, and it is opt-in by construction: the
//  notifications carry no artwork, so it has to come from the player's
//  scripting dictionary, which needs Automation permission. HeyMate only
//  fetches art once macOS already reports that permission as granted
//  (the first tap on a transport control asks). Artwork never causes a
//  permission panel on its own.
//

import AppKit
import Combine
import CoreServices
import Foundation

@MainActor
final class NowPlayingMonitor: ObservableObject {

    /// nil when nothing is playing (or playback is paused).
    @Published private(set) var activity: NotchActivity?

    /// Full metadata for the expanded card, which has room for more than
    /// the pill's ~14 characters.
    @Published private(set) var nowPlaying: NowPlayingSnapshot?

    /// Album art for the current track, when the player allows it.
    @Published private(set) var artwork: NSImage?

    /// Track the artwork belongs to, so a slow fetch for the previous song
    /// can't land on the next one.
    private var artworkTrackKey: String?

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
        clearArtwork()
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
            clearArtwork()
            return
        }

        let trackTitle = (userInfo["Name"] as? String) ?? ""
        let trackArtist = (userInfo["Artist"] as? String) ?? ""
        guard !trackTitle.isEmpty else { return }

        let sourceAppName = notification.name == Self.spotifyNotification ? "Spotify" : "Music"

        let snapshot = NowPlayingSnapshot(
            appName: sourceAppName,
            title: trackTitle,
            artist: trackArtist,
            isPlaying: true
        )
        nowPlaying = snapshot
        refreshArtworkIfPermitted(for: snapshot)
        activity = NotchActivity(
            kind: .media,
            trailingText: Self.pillLabel(forTrackTitle: trackTitle)
        )
    }

    /// The pill's trailing slot is roughly 48 pt wide.
    nonisolated static func pillLabel(forTrackTitle trackTitle: String) -> String {
        NotchActivity.pillText(trackTitle)
    }

    // MARK: Transport

    /// Play/pause the app that produced the current snapshot. Uses the
    /// documented scripting interface, which is why this stays behind a
    /// user-initiated button rather than running automatically.
    func togglePlayPause() { sendTransportCommand("playpause") }
    func skipToNextTrack() { sendTransportCommand("next track") }
    func skipToPreviousTrack() { sendTransportCommand("previous track") }

    /// `AppleScript.run` spawns osascript and blocks
    /// until it exits, so it must never run on the main actor — a slow
    /// Apple Event would freeze the notch mid-animation.
    private func sendTransportCommand(_ command: String) {
        guard let appName = nowPlaying?.appName else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = AppleScript.run(
                "tell application \"\(appName)\" to \(command)"
            )
            // The command may have just granted Automation; try for art now
            // rather than waiting for the next track.
            await self?.retryArtworkAfterTransport()
        }
    }

    // MARK: Artwork

    private func retryArtworkAfterTransport() {
        guard let nowPlaying, artwork == nil else { return }
        artworkTrackKey = nil
        refreshArtworkIfPermitted(for: nowPlaying)
    }

    private func clearArtwork() {
        artwork = nil
        artworkTrackKey = nil
    }

    private func refreshArtworkIfPermitted(for snapshot: NowPlayingSnapshot) {
        let trackKey = Self.artworkKey(for: snapshot)
        guard trackKey != artworkTrackKey else { return }
        artworkTrackKey = trackKey
        artwork = nil

        let playerName = snapshot.appName
        Task.detached(priority: .utility) { [weak self] in
            // Both the permission check and the Apple Event are IPC that can
            // block, so neither may run on the main actor.
            guard let bundleIdentifier = Self.bundleIdentifier(forPlayerNamed: playerName),
                  Self.isAutomationAlreadyPermitted(bundleIdentifier: bundleIdentifier) else {
                await self?.forgetArtworkAttempt(forTrackKey: trackKey)
                return
            }
            let data = await Self.artworkData(fromPlayerNamed: playerName)
            await self?.applyArtwork(data, forTrackKey: trackKey)
        }
    }

    private func applyArtwork(_ data: Data?, forTrackKey trackKey: String) {
        guard artworkTrackKey == trackKey else { return }
        artwork = data.flatMap(NSImage.init(data:))
    }

    /// Not permitted yet: forget the attempt so a later event can retry
    /// once the user has granted Automation.
    private func forgetArtworkAttempt(forTrackKey trackKey: String) {
        guard artworkTrackKey == trackKey else { return }
        artworkTrackKey = nil
    }

    nonisolated static func artworkKey(for snapshot: NowPlayingSnapshot) -> String {
        "\(snapshot.appName)|\(snapshot.title)|\(snapshot.artist)"
    }

    nonisolated static func bundleIdentifier(forPlayerNamed playerName: String) -> String? {
        switch playerName {
        case "Music": return "com.apple.Music"
        case "Spotify": return "com.spotify.client"
        default: return nil
        }
    }

    /// Asks TCC without ever showing a prompt (`askUserIfNeeded: false`).
    nonisolated static func isAutomationAlreadyPermitted(bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let addressDescriptor = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(
            addressDescriptor,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        return status == noErr
    }

    /// Spotify exposes an artwork URL; Music exposes the raw image, which
    /// AppleScript can only hand back by writing it to a file.
    nonisolated static func artworkData(fromPlayerNamed playerName: String) async -> Data? {
        switch playerName {
        case "Spotify":
            let result = AppleScript.run(
                "tell application \"Spotify\" to artwork url of current track"
            )
            guard result.succeeded, let url = spotifyArtworkURL(fromScriptOutput: result.output) else { return nil }
            return try? await URLSession.shared.data(from: url).0

        case "Music":
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("heymate-artwork-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let script = """
            tell application "Music"
                if (count of artworks of current track) is 0 then return "none"
                set artworkData to raw data of artwork 1 of current track
            end tell
            set artworkFile to open for access (POSIX file "\(fileURL.path)") with write permission
            set eof artworkFile to 0
            write artworkData to artworkFile
            close access artworkFile
            return "ok"
            """
            let result = AppleScript.run(script)
            guard result.succeeded, result.output.contains("ok") else { return nil }
            return try? Data(contentsOf: fileURL)

        default:
            return nil
        }
    }

    /// `osascript -ss` prints the value as AppleScript source, i.e. quoted.
    /// Only HTTPS URLs are fetched.
    nonisolated static func spotifyArtworkURL(fromScriptOutput output: String) -> URL? {
        let unquoted = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let url = URL(string: unquoted), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
