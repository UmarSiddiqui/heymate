//
//  AppBundleConfiguration.swift
//  HeyMate
//
//  Build-time settings (backend URLs, optional analytics keys) that the build
//  writes into Info.plist. Blank values count as unset, so a key left empty
//  in the project behaves exactly like a missing one.
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        nonBlank(Bundle.main.object(forInfoDictionaryKey: key))
            ?? nonBlank(bundledInfoPlist?[key])
    }

    /// Info.plist copied in as a plain resource. Some build setups only
    /// expose custom keys this way, so it is the fallback, read once.
    private static let bundledInfoPlist: NSDictionary? = Bundle.main
        .url(forResource: "Info", withExtension: "plist")
        .flatMap { NSDictionary(contentsOf: $0) }

    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
