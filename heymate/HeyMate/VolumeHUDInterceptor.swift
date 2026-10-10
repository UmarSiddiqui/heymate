//
//  VolumeHUDInterceptor.swift
//  HeyMate
//
//  Optional volume-key replacement. Accessibility-authorized event tap
//  consumes only volume keys, updates CoreAudio, and publishes a notch HUD.
//

import AppKit
import Combine
import Foundation

@MainActor
final class VolumeHUDInterceptor: ObservableObject {
    @Published private(set) var activity: NotchActivity?

    private enum MediaKey: Int {
        case volumeUp = 0
        case volumeDown = 1
        case mute = 7
    }

    private lazy var keyTap = SystemMediaKeyTap { [weak self] press in
        self?.handle(press) ?? false
    }
    private var clearTask: Task<Void, Never>?
    private var volumeBeforeMute: Float = 0.5

    func start() {
        keyTap.start()
    }

    func stop() {
        clearTask?.cancel()
        clearTask = nil
        keyTap.stop()
        activity = nil
    }

    private func handle(_ press: SystemMediaKeyPress) -> Bool {
        guard let mediaKey = MediaKey(rawValue: press.keyCode) else { return false }

        // Keep native Option-volume behavior (open Sound settings).
        if press.wantsNativeSettingsShortcut { return false }

        if press.isKeyDown {
            apply(mediaKey, fineAdjustment: press.wantsFineAdjustment)
        }
        // Consume both down and up so macOS does not draw a second HUD.
        return true
    }

    private func apply(_ key: MediaKey, fineAdjustment: Bool) {
        let current = HeyMateSystemOutputVolume.currentScalar() ?? 0.5
        let step: Float = fineAdjustment ? 1 / 64 : 1 / 16
        let newVolume: Float

        switch key {
        case .volumeUp:
            newVolume = HeyMateSystemOutputVolume.clampedScalar(current + step)
        case .volumeDown:
            newVolume = HeyMateSystemOutputVolume.clampedScalar(current - step)
        case .mute:
            if current > 0.001 {
                volumeBeforeMute = current
                newVolume = 0
            } else {
                newVolume = max(volumeBeforeMute, 1 / 16)
            }
        }

        guard HeyMateSystemOutputVolume.setScalar(newVolume) else { return }
        publish(volume: newVolume)
    }

    private func publish(volume: Float) {
        clearTask?.cancel()
        activity = NotchActivity(
            kind: .volume,
            trailingText: volume <= 0.001 ? "Muted" : "\(Int((volume * 100).rounded()))%",
            progress: Double(volume),
            expiresAt: Date().addingTimeInterval(1.3)
        )
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_300))
            guard !Task.isCancelled else { return }
            self?.activity = nil
        }
    }
}
