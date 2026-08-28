//
//  AudioInputDeviceCatalog.swift
//  leanring-buddy
//
//  Lists the machine's audio input devices and remembers which one the user
//  picked for push-to-talk. Before this, capture always used whatever macOS
//  had as the system default input, which is wrong on any desk with both a
//  headset and an interface plugged in.
//
//  Devices are identified by their CoreAudio UID string rather than by
//  AudioDeviceID, because IDs are reassigned across reboots and replugs while
//  UIDs are stable.
//

import AVFoundation
import CoreAudio
import Foundation

nonisolated struct AudioInputDevice: Identifiable, Hashable {
    /// CoreAudio device UID. Stable across reboots; this is what gets stored.
    let id: String
    let name: String
    /// The live CoreAudio id, only valid for this run of the app.
    let audioDeviceID: AudioDeviceID
}

nonisolated enum AudioInputDeviceCatalog {

    /// Stored value for "whatever macOS considers the default input", which
    /// stays the default so nothing changes for users who never open the
    /// picker.
    static let systemDefaultDeviceID = "system-default"

    static let preferenceKey = "selectedAudioInputDeviceUID"

    /// Every device that currently has at least one input channel.
    static func availableInputDevices() -> [AudioInputDevice] {
        allAudioDeviceIDs()
            .filter { hasInputChannels($0) }
            .compactMap { audioDeviceID in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: audioDeviceID),
                      let name = stringProperty(kAudioObjectPropertyName, for: audioDeviceID) else {
                    return nil
                }
                return AudioInputDevice(id: uid, name: name, audioDeviceID: audioDeviceID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The UID the user picked, or `systemDefaultDeviceID`.
    static var selectedDeviceUID: String {
        get {
            UserDefaults.standard.string(forKey: preferenceKey) ?? systemDefaultDeviceID
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
        }
    }

    /// Display name for the current selection, for a settings footnote.
    static func selectedDeviceDisplayName() -> String {
        let uid = selectedDeviceUID
        guard uid != systemDefaultDeviceID else { return "System default" }
        guard let match = availableInputDevices().first(where: { $0.id == uid }) else {
            // Selected device is unplugged. Capture silently falls back to the
            // system default, and the UI should say so rather than show a name
            // for hardware that is not there.
            return "Unavailable — using system default"
        }
        return match.name
    }

    /// The live CoreAudio id to hand the capture engine, or nil to mean
    /// "leave the engine on the system default".
    static func resolvedAudioDeviceID() -> AudioDeviceID? {
        let uid = selectedDeviceUID
        guard uid != systemDefaultDeviceID else { return nil }
        return availableInputDevices().first(where: { $0.id == uid })?.audioDeviceID
    }

    // MARK: CoreAudio plumbing

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs
    }

    private static func hasInputChannels(_ audioDeviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(
            audioDeviceID, &address, 0, nil, &dataSize, bufferListPointer
        ) == noErr else { return false }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return audioBufferList.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for audioDeviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &dataSize, valuePointer)
        }
        guard status == noErr else { return nil }

        let stringValue = value as String
        return stringValue.isEmpty ? nil : stringValue
    }
}
