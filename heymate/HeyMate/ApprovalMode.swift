//
//  ApprovalMode.swift
//  HeyMate
//
//  One switch for how often HeyMate stops to ask. "Ask me" is the default
//  and keeps every existing gate. "Full access" lets ordinary work through
//  without a card: computer clicks and typing, reversible connector writes,
//  and job plans.
//
//  The floor never moves. Credentials are refused outright, and sending,
//  deleting, paying, and destructive keys always ask, in either mode.
//

import Foundation

nonisolated enum ApprovalMode: String, CaseIterable, Sendable {
    case askMe
    case fullAccess

    static let preferenceKey = "approvalMode"

    var title: String {
        switch self {
        case .askMe: return "Ask me"
        case .fullAccess: return "Full access"
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> ApprovalMode {
        defaults.string(forKey: preferenceKey).flatMap(ApprovalMode.init(rawValue:)) ?? .askMe
    }

    /// The connector policy in force. Full access lifts reversible writes
    /// only; `ConnectorApprovalPolicy` still asks for sends and deletes.
    func connectorPolicy(_ chosen: ConnectorApprovalPolicy) -> ConnectorApprovalPolicy {
        self == .fullAccess ? .askForExternalEffects : chosen
    }

    /// Computer input that may run without a card. Destructive chords
    /// (quit, close, delete) always ask; protected labels such as Send and
    /// Delete are refused by the executor before any click.
    func skipsComputerUseApproval(for risk: ConnectorToolRisk) -> Bool {
        self == .fullAccess && risk < .destructive
    }

    /// A plan may start on its own only in full access and only when it
    /// does not touch the floor.
    func autoApprovesPlan(_ planText: String) -> Bool {
        self == .fullAccess && ApprovalFloor.reasonPlanNeedsHuman(planText) == nil
    }
}

/// Words that mean a plan crosses the line no mode lifts. Deliberately
/// broad: a false alarm costs one click, a miss could send an email.
/// Matched as whole words, so "display" is not "pay".
nonisolated enum ApprovalFloor {
    static let planTriggers: [(reason: String, words: [String])] = [
        ("sends something", ["send", "sends", "sending", "email", "emails", "e-mail", "reply", "post", "publish", "tweet", "invite", "share"]),
        ("deletes something", ["delete", "deletes", "deleting", "remove", "removes", "removing", "rm", "trash", "erase", "wipe", "drop", "overwrite", "force-push", "--force", "--hard"]),
        ("handles money or credentials", ["pay", "payment", "purchase", "buy", "checkout", "transfer", "password", "passwords", "credential", "credentials", "token", "tokens", "secret", "secrets"]),
    ]

    /// Why this plan still needs a yes, or nil when full access may start it.
    static func reasonPlanNeedsHuman(_ planText: String) -> String? {
        let words = Set(planText.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty })
        for trigger in planTriggers where trigger.words.contains(where: words.contains) {
            return trigger.reason
        }
        return nil
    }
}
