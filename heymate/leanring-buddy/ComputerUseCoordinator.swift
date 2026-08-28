//
//  ComputerUseCoordinator.swift
//  leanring-buddy
//
//  The gate between "the model asked" and "the Mac did".
//
//  Every requested action lands here first. Read-only ones run
//  immediately. Anything that clicks, types, drags, or sends is published
//  as `pendingRequest`, and nothing happens until a human answers. There
//  is no policy setting that removes that gate for destructive actions —
//  that floor is deliberate.
//
//  One request at a time, on purpose: a queue of pending approvals is a
//  queue of things a user will click through without reading.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ComputerUseCoordinator: ObservableObject {

    /// UserDefaults key for the master switch. Off until the user turns it
    /// on, because an assistant that can drive the machine is a different
    /// product than one that can only talk about it.
    nonisolated static let enabledPreferenceKey = "computerUseEnabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledPreferenceKey) }
    }

    /// The action waiting on the user. nil when nothing is pending.
    @Published private(set) var pendingRequest: ComputerUseRequest?

    /// Last thing that happened, for the card to show after the sheet
    /// closes. Cleared when a new request arrives.
    @Published private(set) var lastOutcomeSummary: String?

    private let executor = ComputerUseExecutor()

    /// Continuation for the in-flight approval, resumed by approve/deny.
    private var pendingApprovalContinuation: CheckedContinuation<Bool, Never>?

    /// Called with the target point just before synthesized input, so the
    /// cursor overlay can fly there and make the action visible.
    var onWillSynthesizeInput: ((CGPoint) -> Void)? {
        get { executor.onWillSynthesizeInput }
        set { executor.onWillSynthesizeInput = newValue }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledPreferenceKey)
    }

    // MARK: Requesting

    /// Run an action, asking first when the risk ladder says to. Returns a
    /// short sentence describing what happened, suitable for speaking back
    /// or appending to the transcript.
    func perform(_ action: ComputerUseAction, statedReason: String) async -> String {
        guard isEnabled else {
            return "Computer control is switched off. Turn it on in Settings if you want me to click things."
        }
        guard AccessibilityElementFinder.isAccessibilityTrusted || action.risk == .readOnly else {
            return ComputerUseError.accessibilityPermissionMissing.localizedDescription
        }

        let request = ComputerUseRequest(action: action, statedReason: statedReason)

        var approvalToken: ComputerUseApprovalToken?
        if action.risk > .readOnly {
            let didApprove = await requestApproval(for: request)
            guard didApprove else {
                lastOutcomeSummary = "Skipped: \(action.approvalDescription.lowercased())."
                return "Okay, I won't."
            }
            approvalToken = .grantedByUser(forRequestID: request.id)
        }

        do {
            let outcome = try await executor.execute(request, approval: approvalToken)
            lastOutcomeSummary = outcome.summary
            if let payload = outcome.payload, !payload.isEmpty {
                return "\(outcome.summary)\n\(payload)"
            }
            return outcome.summary
        } catch {
            let message = error.localizedDescription
            lastOutcomeSummary = message
            return message
        }
    }

    /// Suspends until the user answers. If something replaces the pending
    /// request before then, the old one resolves as denied — silently
    /// dropping a suspended approval would hang the caller forever.
    private func requestApproval(for request: ComputerUseRequest) async -> Bool {
        pendingApprovalContinuation?.resume(returning: false)
        pendingApprovalContinuation = nil

        lastOutcomeSummary = nil
        pendingRequest = request
        NSSound.beep()

        return await withCheckedContinuation { continuation in
            pendingApprovalContinuation = continuation
        }
    }

    // MARK: Answering

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
