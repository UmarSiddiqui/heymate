//
//  QuietPolicy.swift
//  HeyMate
//
//  When the user is on a call, sharing their screen, or in Focus, HeyMate
//  stays quiet: no interaction chimes, spoken captions, or proactive nudges.
//

import CoreAudio
import Foundation

nonisolated enum QuietPolicy {

    static func shouldSilenceAnnouncements() -> Bool {
        shouldSilence(
            callsActive: liveCallsActive(),
            screenSharing: liveScreenSharing(),
            focusActive: liveFocusActive()
        )
    }

    static func shouldSilence(callsActive: Bool, screenSharing: Bool, focusActive: Bool) -> Bool {
        callsActive || screenSharing || focusActive
    }

    // MARK: - Live sensors

    /// Another process is recording from a microphone. HeyMate's own
    /// listening does not count, or every talk turn would silence itself.
    /// Fails open to false when CoreAudio cannot answer.
    private static func liveCallsActive() -> Bool {
        isAnotherProcessRecording(
            inputRunningPIDs: inputRunningProcessIDs(),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func isAnotherProcessRecording(inputRunningPIDs: [pid_t], ownPID: pid_t) -> Bool {
        inputRunningPIDs.contains { $0 != ownPID }
    }

    /// No presenter API exists at the deployment target, so screen sharing
    /// is not detected yet.
    private static func liveScreenSharing() -> Bool {
        false
    }

    /// HeyMate does not read system Focus / Do Not Disturb yet.
    private static func liveFocusActive() -> Bool {
        false
    }

    // MARK: - CoreAudio

    private static func inputRunningProcessIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var processObjects = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &processObjects) == noErr else {
            return []
        }
        return processObjects.compactMap { object in
            guard uint32Property(kAudioProcessPropertyIsRunningInput, for: object) == 1,
                  let pid = uint32Property(kAudioProcessPropertyPID, for: object) else { return nil }
            return pid_t(bitPattern: pid)
        }
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        for object: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value) == noErr else { return nil }
        return value
    }
}
