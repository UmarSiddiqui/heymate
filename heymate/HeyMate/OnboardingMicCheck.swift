//
//  OnboardingMicCheck.swift
//  HeyMate
//
//  "Can I hear you?" in the welcome tour: a live level meter on the chosen
//  microphone, so a wrong or muted mic shows up now rather than as a silent
//  first question. Runs its own short-lived audio engine only while the
//  step is on screen; push-to-talk is not involved and nothing is recorded.
//

import AVFoundation
import Combine
import CoreAudio
import Foundation

@MainActor
final class OnboardingMicCheck: ObservableObject {
    /// 0...1, smoothed like the push-to-talk waveform.
    @Published private(set) var level: CGFloat = 0
    /// True once the meter has seen something louder than room noise.
    @Published private(set) var hasHeardSound = false
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String = AudioInputDeviceCatalog.selectedDeviceUID {
        didSet {
            guard selectedDeviceUID != oldValue else { return }
            AudioInputDeviceCatalog.selectedDeviceUID = selectedDeviceUID
            restart()
        }
    }
    @Published private(set) var errorMessage: String?

    /// Above this counts as the person saying something, not a fan.
    private static let speechThreshold: CGFloat = 0.12

    private var engine: AVAudioEngine?

    func start() {
        devices = AudioInputDeviceCatalog.availableInputDevices()
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = "Turn on Microphone for HeyMate first."
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID = AudioInputDeviceCatalog.resolvedAudioDeviceID(), let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let meter = AudioLevelMeter { [weak self] level in self?.publish(level) }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            meter.measure(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            errorMessage = nil
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't open that microphone. Try another one."
            HeyMateLog.log("⚠️ Onboarding mic check couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    private func restart() {
        stop()
        hasHeardSound = false
        start()
    }

    private func publish(_ raw: CGFloat) {
        guard engine != nil else { return }
        level = max(raw, level * 0.72)
        if raw > Self.speechThreshold { hasHeardSound = true }
    }
}
