//
//  VolumeHUDInterceptor.swift
//  leanring-buddy
//
//  Optional volume-key replacement. Accessibility-authorized event tap
//  consumes only volume keys, updates CoreAudio, and publishes a notch HUD.
//

import AppKit
import ApplicationServices
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

    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clearTask: Task<Void, Never>?
    private var volumeBeforeMute: Float = 0.5

    func start() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, eventType, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<VolumeHUDInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    interceptor.handle(eventType: eventType, event: event)
                }
            },
            userInfo: pointer
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        clearTask?.cancel()
        clearTask = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        activity = nil
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard eventType == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = (data & 0xFFFF_0000) >> 16
        let keyState = (data & 0xFF00) >> 8
        guard let mediaKey = MediaKey(rawValue: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // Keep native Option-volume behavior (open Sound settings).
        if nsEvent.modifierFlags.contains(.option),
           !nsEvent.modifierFlags.contains(.shift) {
            return Unmanaged.passUnretained(event)
        }

        if keyState == 0xA {
            apply(mediaKey, fineAdjustment: nsEvent.modifierFlags.contains([.option, .shift]))
        }
        // Consume both down and up so macOS does not draw a second HUD.
        return nil
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
