//
//  LocalVoiceAction.swift
//  leanring-buddy
//
//  Dump-list alternative to OpenClicky's 13-guard cascade: a sub-100ms
//  fast-path for "open Safari" and "volume up". Not computer use. Referential
//  "open this" stays Talk.
//

import AppKit
import Foundation

nonisolated enum LocalVoiceAction: Equatable {
    case openApp(name: String)
    case volumeUp
    case volumeDown
    case mute
    case unmute
    case setVolume(percent: Int)

    static func parse(_ transcript: String) -> LocalVoiceAction? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard !normalized.isEmpty else { return nil }

        if let volume = parseVolume(normalized) {
            return volume
        }
        return parseOpenApp(normalized)
    }

    var spokenAcknowledgement: String {
        switch self {
        case .openApp(let name):
            return "opening \(name)."
        case .volumeUp:
            return "turned volume up."
        case .volumeDown:
            return "turned volume down."
        case .mute:
            return "muted."
        case .unmute:
            return "unmuted."
        case .setVolume(let percent):
            return "set volume to \(percent) percent."
        }
    }

    @MainActor
    func perform() -> Bool {
        switch self {
        case .openApp(let name):
            return HeyMateAppLauncher.open(named: name)
        case .volumeUp:
            return HeyMateSystemOutputVolume.adjust(by: 0.1) != nil
        case .volumeDown:
            return HeyMateSystemOutputVolume.adjust(by: -0.1) != nil
        case .mute:
            return HeyMateSystemOutputVolume.setScalar(0)
        case .unmute:
            let current = HeyMateSystemOutputVolume.currentScalar() ?? 0
            let restored = current < 0.02 ? 0.4 : current
            return HeyMateSystemOutputVolume.setScalar(restored)
        case .setVolume(let percent):
            return HeyMateSystemOutputVolume.setScalar(Float(percent) / 100)
        }
    }

    private static func parseVolume(_ normalized: String) -> LocalVoiceAction? {
        if normalized.range(
            of: #"\b(?:mute|silence)\b"#,
            options: .regularExpression
        ) != nil,
           normalized.range(of: #"\bunmute\b"#, options: .regularExpression) == nil,
           !normalized.contains("spotify") {
            if normalized == "mute"
                || normalized.hasPrefix("mute volume")
                || normalized.hasPrefix("mute the volume")
                || normalized == "silence"
                || normalized.hasPrefix("mute system") {
                return .mute
            }
        }
        if normalized.range(of: #"\bunmute\b"#, options: .regularExpression) != nil {
            return .unmute
        }
        if let percent = volumePercent(in: normalized) {
            return .setVolume(percent: percent)
        }
        if matchesVolumeUp(normalized) { return .volumeUp }
        if matchesVolumeDown(normalized) { return .volumeDown }
        return nil
    }

    private static func matchesVolumeUp(_ normalized: String) -> Bool {
        let pattern = #"^(?:volume\s+up|system\s+volume\s+up|turn\s+(?:the\s+)?(?:system\s+)?volume\s+up|increase\s+(?:the\s+)?volume|raise\s+(?:the\s+)?volume|turn\s+it\s+up|louder|make\s+it\s+louder)$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func matchesVolumeDown(_ normalized: String) -> Bool {
        let pattern = #"^(?:volume\s+down|system\s+volume\s+down|turn\s+(?:the\s+)?(?:system\s+)?volume\s+down|decrease\s+(?:the\s+)?volume|lower\s+(?:the\s+)?volume|turn\s+it\s+down|quieter|make\s+it\s+quieter)$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func volumePercent(in normalized: String) -> Int? {
        let pattern = #"^(?:set\s+)?(?:the\s+)?(?:system\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized),
              let value = Int(normalized[range]) else {
            return nil
        }
        return min(max(value, 0), 100)
    }

    private static func parseOpenApp(_ normalized: String) -> LocalVoiceAction? {
        let pattern = #"^(?:open|launch|start)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized) else {
            return nil
        }
        var name = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("the ") {
            name = String(name.dropFirst(4))
        }
        guard !name.isEmpty else { return nil }
        guard SpokenText.wordCount(in: name) <= 3 else { return nil }
        let blocked = [
            "this", "that", "it", "them", "here",
            "file", "folder", "files", "app", "application", "window"
        ]
        if blocked.contains(name) { return nil }
        if name.hasPrefix("this ") || name.hasPrefix("that ") { return nil }
        let codingArtifacts = ["landing", "website", "webpage", "project", "component"]
        if codingArtifacts.contains(where: { name.contains($0) }) { return nil }
        return .openApp(name: name)
    }
}

enum HeyMateAppLauncher {
    static func open(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let bundleID = bundleID(for: trimmed),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return open(url: url)
        }

        let running = NSWorkspace.shared.runningApplications.first { app in
            app.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if let bundleID = running?.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return open(url: url)
        }

        let appName = trimmed.hasSuffix(".app") ? trimmed : "\(trimmed).app"
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: applications.path) {
            return open(url: applications)
        }

        let systemApplications = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
            .appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: systemApplications.path) {
            return open(url: systemApplications)
        }

        return false
    }

    private static func open(url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    private static func bundleID(for name: String) -> String? {
        let key = name.lowercased()
        switch key {
        case "safari": return "com.apple.Safari"
        case "mail": return "com.apple.mail"
        case "notes": return "com.apple.Notes"
        case "calendar": return "com.apple.iCal"
        case "messages": return "com.apple.MobileSMS"
        case "finder": return "com.apple.finder"
        case "music": return "com.apple.Music"
        case "photos": return "com.apple.Photos"
        case "terminal": return "com.apple.Terminal"
        case "xcode": return "com.apple.dt.Xcode"
        case "preview": return "com.apple.Preview"
        case "system settings", "settings": return "com.apple.systempreferences"
        default: return nil
        }
    }
}
