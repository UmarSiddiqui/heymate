//
//  DrawingSoundPlayer.swift
//  HeyMate
//
//  The sound of a drawing as it is painted. ReferenceRenderer's canvas says what each
//  mark sounds like (markSound: a texture under the stroke and a few moments);
//  this plays HeyMate's own sounds for them (Draw* assets, synthesized by
//  scripts/generate_ui_sounds.py --drawing). A texture loops while any stroke
//  that uses it is drawing; a moment plays once, timed to its mark.
//

import AVFoundation
import AppKit

@MainActor
final class DrawingSoundPlayer {
    private static let textures = ["felt": "DrawFelt", "pencil": "DrawPencil", "writing": "DrawWriting", "eraser": "DrawEraser"]
    private static let moments = [
        "paper-place": "DrawPaperPlace", "tape": "DrawTape", "photo-drop": "DrawPhotoDrop", "pop": "DrawPop",
        "target-ping": "DrawTargetPing", "pen-flick": "DrawPenFlick", "build-3d": "DrawBuild3D", "slide": "DrawSlide",
        "page-clear": "DrawPageClear", "highlighter": "DrawHighlighter", "type-keys": "DrawTypeKeys", "copy-tick": "DrawCopyTick",
        "tada": "DrawTada", "ding": "DrawDing", "nope": "DrawNope", "stamp": "DrawStamp", "sparkle": "DrawSparkle",
        "whoosh": "DrawWhoosh", "boing": "DrawBoing", "page-turn": "DrawPageTurn",
    ]
    private static let textureVolume: Float = 0.35
    private static let momentVolume: Float = 0.5

    private var loops: [String: AVAudioPlayer] = [:]
    /// Until when each texture is wanted (system uptime).
    private var wantedUntil: [String: TimeInterval] = [:]
    private var moments: [AVAudioPlayer] = []
    private var ticker: Timer?

    /// One mark's sound, as the canvas describes it: {texture, events: [{id, at, end}], delay, dur} in seconds from now.
    private var announced = false
    func play(_ description: [String: Any]) {
        guard UISoundPlayer.shared.isSoundEnabled else { return }
        if !announced { announced = true; HeyMateLog.log("🔊 Drawing sounds: playing (texture \(description["texture"] ?? "none"))") }
        let delay = max(0, description["delay"] as? Double ?? 0), duration = max(0, description["dur"] as? Double ?? 0)
        if let texture = description["texture"] as? String, let asset = Self.textures[texture], duration > 0.05 {
            schedule(after: delay) { [weak self] in self?.hold(asset, for: duration) }
        }
        for case let event as [String: Any] in description["events"] as? [Any] ?? [] {
            guard let id = event["id"] as? String, let asset = Self.moments[id] else { continue }
            let at = event["at"] as? Double ?? 0
            let when = delay + (event["end"] as? Bool == true ? duration : 0) + at
            schedule(after: max(0, when)) { [weak self] in self?.playOnce(asset) }
        }
    }

    func stopAll() {
        announced = false
        ticker?.invalidate(); ticker = nil
        loops.values.forEach { $0.stop() }
        loops.removeAll(); wantedUntil.removeAll()
        moments.forEach { $0.stop() }
        moments.removeAll()
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
    }

    private func hold(_ asset: String, for duration: TimeInterval) {
        let until = ProcessInfo.processInfo.systemUptime + duration
        wantedUntil[asset] = max(wantedUntil[asset] ?? 0, until)
        if loops[asset] == nil, let player = Self.player(asset) {
            player.numberOfLoops = -1
            player.currentTime = Double.random(in: 0..<max(0.01, player.duration))
            player.volume = 0
            player.play()
            player.setVolume(Self.textureVolume, fadeDuration: 0.04)
            loops[asset] = player
        }
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseFinishedTextures() }
            }
        }
    }

    private func releaseFinishedTextures() {
        let now = ProcessInfo.processInfo.systemUptime
        for (asset, until) in wantedUntil where until <= now {
            wantedUntil[asset] = nil
            if let player = loops.removeValue(forKey: asset) {
                player.setVolume(0, fadeDuration: 0.08)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { player.stop() }
            }
        }
        if wantedUntil.isEmpty { ticker?.invalidate(); ticker = nil }
    }

    private func playOnce(_ asset: String) {
        moments.removeAll { !$0.isPlaying }
        guard moments.count < 8, let player = Self.player(asset) else { return }
        player.volume = Self.momentVolume
        player.play()
        moments.append(player)
    }

    private static func player(_ asset: String) -> AVAudioPlayer? {
        guard let data = NSDataAsset(name: asset)?.data, let player = try? AVAudioPlayer(data: data) else {
            HeyMateLog.log("🔇 DrawingSoundPlayer: missing sound asset \(asset)")
            return nil
        }
        player.prepareToPlay()
        return player
    }
}
