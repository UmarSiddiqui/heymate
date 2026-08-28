//
//  ConnectorToolCoordinator.swift
//  leanring-buddy
//
//  The approval gate for a connector tool call the Talk model wants to
//  make — the same "ask before anything with real-world reach" contract
//  `ComputerUseCoordinator` already enforces for computer control, applied
//  to connector calls instead. `ConnectorApprovalPolicy.requiresApproval`
//  is the actual policy; this coordinator only owns the suspend/resume
//  plumbing and the one-pending-request-at-a-time rule.
//

import AppKit
import Combine
import Foundation

/// One connector tool call waiting on the user, and everything the
/// approval card needs to describe it.
struct ConnectorToolApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let connectorDisplayName: String
    let toolName: String
    let argumentsSummary: String
    let risk: ConnectorToolRisk
}

@MainActor
final class ConnectorToolCoordinator: ObservableObject {

    /// The call waiting on the user. nil when nothing is pending.
    @Published private(set) var pendingRequest: ConnectorToolApprovalRequest?

    /// Continuation for the in-flight approval, resumed by approve/deny.
    private var pendingApprovalContinuation: CheckedContinuation<Bool, Never>?

    /// Suspends until the user answers. If another request replaces this
    /// one before then, the earlier one resolves as denied — silently
    /// dropping a suspended approval would hang its caller forever.
    func requestApproval(for request: ConnectorToolApprovalRequest) async -> Bool {
        pendingApprovalContinuation?.resume(returning: false)
        pendingApprovalContinuation = nil

        pendingRequest = request
        NSSound.beep()

        return await withCheckedContinuation { continuation in
            pendingApprovalContinuation = continuation
        }
    }

    func approvePendingRequest() {
        resolvePendingRequest(approved: true)
    }

    func denyPendingRequest() {
        resolvePendingRequest(approved: false)
    }

    private func resolvePendingRequest(approved: Bool) {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        pendingApprovalContinuation?.resume(returning: approved)
        pendingApprovalContinuation = nil
    }
}
