//
//  CursorCompanionPreference.swift
//  HeyMate
//
//  Whether the cursor companion stays deployed beside the pointer. Defaults to
//  on. Builds before the rename stored this under a different key; it is read
//  once as a fallback and then moved, so nobody's choice is lost on update.
//

import Foundation

nonisolated enum CursorCompanionPreference {
    static let defaultsKey = "isCursorCompanionEnabled"
    static let legacyDefaultsKey = "isClickyCursorEnabled"

    static func storedValue(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        guard defaults.object(forKey: legacyDefaultsKey) != nil else { return true }
        let legacyValue = defaults.bool(forKey: legacyDefaultsKey)
        defaults.set(legacyValue, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyDefaultsKey)
        return legacyValue
    }

    static func store(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
