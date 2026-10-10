//
//  SystemVolume.swift
//  HeyMate
//
//  Reads and sets the Mac's output volume through CoreAudio, for voice
//  commands ("volume up") and the volume keys. Some devices only expose
//  per-channel volume, so the main control is tried first, then the left
//  and right channels.
//

import CoreAudio
import Foundation

nonisolated enum SystemVolume {
    static func clampedScalar(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// The volume from 0 to 1, or nil when the output has no volume control.
    static func currentScalar() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        if let main = volume(kAudioObjectPropertyElementMain).read(Float32.self, from: device) { return main }
        let channels = stereoChannels.compactMap { volume($0).read(Float32.self, from: device) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }

    /// Sets the volume (clamped to 0…1). False when nothing could be set.
    @discardableResult
    static func setScalar(_ scalar: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let value = Float32(clampedScalar(scalar))
        if volume(kAudioObjectPropertyElementMain).write(value, to: device) { return true }
        // Every channel is set; success if any of them took it.
        return stereoChannels.map { volume($0).write(value, to: device) }.contains(true)
    }

    /// Moves the volume by `delta` and returns where it landed.
    @discardableResult
    static func adjust(by delta: Float) -> Float? {
        let target = clampedScalar((currentScalar() ?? 0.5) + delta)
        return setScalar(target) ? target : nil
    }

    /// True when sound plays through the Mac's own speakers rather than
    /// headphones, AirPods or a display. The wired headphone jack belongs to
    /// the same built-in device, so its data source tells the two apart.
    static func isDefaultOutputBuiltInSpeaker() -> Bool {
        guard let device = defaultOutputDevice(),
              CoreAudioProperty(kAudioDevicePropertyTransportType).read(UInt32.self, from: device)
                == kAudioDeviceTransportTypeBuiltIn
        else { return false }

        let dataSource = CoreAudioProperty(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        // Without a headphone jack there is no data source: it's the speakers.
        guard dataSource.exists(on: device), let source = dataSource.read(UInt32.self, from: device) else {
            return true
        }
        return source != headphonesDataSource
    }

    // MARK: - CoreAudio

    private static let stereoChannels: [AudioObjectPropertyElement] = [1, 2]
    /// The four-character code 'hdpn'.
    private static let headphonesDataSource: UInt32 = 0x6864_706E

    private static func volume(_ element: AudioObjectPropertyElement) -> CoreAudioProperty {
        CoreAudioProperty(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        let device = CoreAudioProperty(kAudioHardwarePropertyDefaultOutputDevice)
            .read(AudioDeviceID.self, from: AudioObjectID(kAudioObjectSystemObject))
        return device == AudioDeviceID(kAudioObjectUnknown) ? nil : device
    }
}

/// One CoreAudio property address with typed, failure-tolerant access.
private nonisolated struct CoreAudioProperty {
    private var address: AudioObjectPropertyAddress

    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func exists(on object: AudioObjectID) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    /// The value, or nil when the object lacks the property or the read fails.
    func read<Value: BinaryInteger & FixedWidthInteger>(_: Value.Type, from object: AudioObjectID) -> Value? {
        var value = Value.zero
        return read(into: &value, from: object) ? value : nil
    }

    func read(_: Float32.Type, from object: AudioObjectID) -> Float32? {
        var value: Float32 = 0
        return read(into: &value, from: object) ? value : nil
    }

    /// Writes only when the property exists and is settable.
    func write(_ value: Float32, to object: AudioObjectID) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue
        else { return false }
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func read<Value>(into value: inout Value, from object: AudioObjectID) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
