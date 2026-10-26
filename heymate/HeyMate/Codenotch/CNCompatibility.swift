import Foundation
import CoreFoundation
import SwiftUI

// HeyMate's narrow host boundary. No upstream app lifecycle, updater, phone
// server, sign-in browser, credential refresh, hook installation or helper start.
nonisolated enum CNL10n {
    static var locale: Locale { .current }
    static func t(_ value: String, locale: Locale = .current) -> String { value }
}
nonisolated enum CNUsageProviderError: Error {
    case needsAuth, credentialExpired, accessDenied
    case badResponse(status: Int)
    case nothingMetered(String)
    case rateLimited(retryAfter: TimeInterval)
}
nonisolated struct CNProviderAccount {
    let label: String?
    let plan: String?
    let source: String
    let manageURL: URL?
}
nonisolated enum CNUsageBand: String, Codable, Equatable {
    case ample, watch, critical, exhausted
    // From Model/UsageBand.swift. Warning thresholds judge spent, even when
    // displaying remaining. A second window can block the primary ring.
    static func band(for usedFraction: Double) -> Self {
        switch usedFraction {
        case ..<0.50: .ample
        case ..<0.70: .watch
        case ..<1: .critical
        default: .exhausted
        }
    }
    var color: Color {
        switch self {
        case .ample: .green
        case .watch: .yellow
        case .critical, .exhausted: .orange
        }
    }
}
nonisolated enum CNAntigravityCredentials {
    static func parse(_ value: String) -> Date? { CNGeminiCLIUsage.parse(value) }
}
nonisolated enum CNNotchLayout {
    static let curlRadius: CGFloat = 10
    static let cornerRadius: CGFloat = 24
    static let activityStroke: CGFloat = 1.4
}
nonisolated enum CNLMStudioError: Error { case invalidResponse }

nonisolated enum CNNumber {
    static func read(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max) else { return nil }
        return number.doubleValue
    }
}

nonisolated enum CNCount {
    static func add(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow, left >= 0, right >= 0 else { CNReadBudget.sqlExceeded(); return 0 }
        return sum
    }
}
