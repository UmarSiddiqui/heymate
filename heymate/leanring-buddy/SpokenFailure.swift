//
//  SpokenFailure.swift
//  leanring-buddy
//
//  Classifies Talk / agent / TTS failures so the companion only says
//  “out of credits” for real model quota/billing errors. Mac listen and
//  speak are local and must never be blamed for a depleted cloud model.
//

import Foundation

nonisolated enum SpokenFailure: Equatable {
    case cancelled
    case outOfCredits
    case generic

    /// Spoken line, or `nil` when the failure should stay silent (cancel).
    var spokenUtterance: String? {
        switch self {
        case .cancelled:
            return nil
        case .outOfCredits:
            return "the selected model is out of credits. listen and speak on this mac don't use credits. pick another model in settings."
        case .generic:
            return "i couldn't complete that. check the selected model in settings."
        }
    }

    static func classify(_ error: Error) -> SpokenFailure {
        if error is CancellationError {
            return .cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return classify(message: error.localizedDescription, code: nsError.code)
    }

    static func classify(message: String, code: Int? = nil) -> SpokenFailure {
        if let code, code == 402 {
            return .outOfCredits
        }
        let lowered = message.lowercased()
        if looksLikeCancellation(lowered) {
            return .cancelled
        }
        if looksLikeCreditExhaustion(lowered) {
            return .outOfCredits
        }
        return .generic
    }

    private static func looksLikeCancellation(_ lowered: String) -> Bool {
        lowered == "cancelled" || lowered.contains("canceled")
    }

    /// Whole-word matches so “credentials” / “credit card field on screen”
    /// do not get billed as a quota failure. `insufficient_quota` uses an
    /// underscore, so it is matched explicitly.
    private static func looksLikeCreditExhaustion(_ lowered: String) -> Bool {
        if lowered.contains("insufficient_quota") { return true }
        if lowered.contains("payment required") { return true }
        if lowered.contains("usage limit") { return true }
        return creditWordPatterns.contains { pattern in
            lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static let creditWordPatterns = [
        #"\bcredits?\b"#,
        #"\bquota\b"#,
        #"\bbilling\b"#,
        #"\b402\b"#
    ]
}
