//
//  ComputerUseCoordinator.swift
//  HeyMate
//
//  The gate between "the model asked" and "the Mac did".
//
//  Every requested action lands here first. Observation runs immediately.
//  Anything that clicks, types, drags, presses keys, or opens an app is
//  published as `pendingRequest`, and nothing happens until a human
//  answers — unless they already said yes for this conversation, or turned
//  on the standing "always" preference. The master switch still has to be
//  on. A standing yes does not turn computer control on by itself.
//
//  One request at a time, on purpose: a queue of pending approvals is a
//  queue of things a user will click through without reading.
//

import AppKit
import Combine
import Foundation

/// How far a yes to synthesized input reaches.
enum ComputerUseConsentScope: Equatable, Sendable {
    /// This action, then ask again.
    case once
    /// Later input in the same conversation, until the app quits.
    case conversation
    /// Later input on this Mac, until the preference is cleared.
    /// Still does nothing while the master switch is off.
    case always
}

@MainActor
protocol ComputerUseExecuting: AnyObject {
    var onWillSynthesizeInput: ((CGPoint) -> Void)? { get set }
    func execute(
        _ request: ComputerUseRequest,
        approval: ComputerUseApprovalToken?
    ) async throws -> ComputerUseOutcome
}

extension ComputerUseExecutor: ComputerUseExecuting {}

@MainActor
final class ComputerUseCoordinator: ObservableObject {

    /// UserDefaults key for the master switch. Off until the user turns it
    /// on, because an assistant that can drive the machine is a different
    /// product than one that can only talk about it.
    nonisolated static let enabledPreferenceKey = "computerUseEnabled"

    /// Standing yes for input actions. Ignored while the master switch is off.
    nonisolated static let alwaysAllowPreferenceKey = "computerUseAlwaysAllow"

    /// What the model should do after the user refuses a click, keystroke,
    /// or typed text. Shared with the MCP bridge, which still cannot do
    /// that input itself.
    nonisolated static let inputRefusalMessage = HeyMateMCPServer.computerUseInputRefusal

    @Published var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Self.enabledPreferenceKey) }
    }

    /// Chat this gate is acting for. A "this chat" yes is stored against
    /// this id. Nil means there is no conversation to remember.
    @Published var conversationID: UUID?

    /// The action waiting on the user. nil when nothing is pending.
    @Published private(set) var pendingRequest: ComputerUseRequest?

    /// Last thing that happened, for the card to show after the sheet
    /// closes. Cleared when a new request arrives.
    @Published private(set) var lastOutcomeSummary: String?

    private let userDefaults: UserDefaults
    private let executor: any ComputerUseExecuting

    /// Conversations whose user already said yes to input for the rest of
    /// that chat. Not persisted: a new launch asks again unless "always" is on.
    private var grantedConversationIDs: Set<UUID> = []

    /// Continuation for the in-flight approval, resumed by approve/deny.
    private var pendingApprovalContinuation: CheckedContinuation<Bool, Never>?

    /// Replaced in tests so approval rules can run without Accessibility
    /// permission. Production uses the real check.
    var accessibilityTrustCheck: @MainActor () -> Bool

    /// Called with the target point just before synthesized input, so the
    /// cursor overlay can fly there and make the action visible.
    var onWillSynthesizeInput: ((CGPoint) -> Void)? {
        get { executor.onWillSynthesizeInput }
        set { executor.onWillSynthesizeInput = newValue }
    }

    init(userDefaults: UserDefaults = .standard, executor: (any ComputerUseExecuting)? = nil) {
        self.userDefaults = userDefaults
        self.executor = executor ?? ComputerUseExecutor()
        self.accessibilityTrustCheck = { AccessibilityElementFinder.isAccessibilityTrusted }
        isEnabled = userDefaults.bool(forKey: Self.enabledPreferenceKey)
    }

    // MARK: Requesting

    /// Run an action, asking first when the risk ladder says to. Returns a
    /// short sentence describing what happened, suitable for speaking back
    /// or appending to the transcript. A refusal is instructions for the
    /// model: finish the other work, then emit a computer-use request.
    func perform(_ action: ComputerUseAction, statedReason: String) async -> String {
        guard !Task.isCancelled else { return "This action was cancelled." }
        guard isEnabled else {
            return "Computer control is switched off. Turn it on in Settings if you want me to click things."
        }
        guard accessibilityTrustCheck() || action.risk == .readOnly else {
            return ComputerUseError.accessibilityPermissionMissing.localizedDescription
        }

        let request = ComputerUseRequest(action: action, statedReason: statedReason)

        var approvalToken: ComputerUseApprovalToken?
        if action.risk > .readOnly {
            if !hasStandingInputGrant() {
                let didApprove = await requestApproval(for: request)
                guard didApprove else {
                    lastOutcomeSummary = "Skipped: \(action.approvalDescription.lowercased())."
                    return Self.inputRefusalMessage
                }
            }
            approvalToken = .grantedByUser(forRequestID: request.id)
        }

        do {
            try Task.checkCancellation()
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
        guard !Task.isCancelled else { return false }
        pendingApprovalContinuation?.resume(returning: false)
        pendingApprovalContinuation = nil

        lastOutcomeSummary = nil
        pendingRequest = request
        NSSound.beep()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApprovalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingRequest?.id == request.id else { return }
                self?.denyPendingRequest()
            }
        }
    }

    // MARK: Answering

    /// Yes for this action only. The next input action asks again.
    func approvePendingRequest() {
        approvePendingRequest(scope: .once)
    }

    /// Yes, and remember how far it reaches. `.conversation` with no
    /// `conversationID` is treated as once. `.always` is the preference,
    /// not a substitute for the master switch.
    func approvePendingRequest(scope: ComputerUseConsentScope) {
        guard pendingRequest != nil else { return }
        record(scope)
        resolvePendingRequest(approved: true)
    }

    func denyPendingRequest() {
        resolvePendingRequest(approved: false)
    }

    /// True when a previous yes already covers this input action.
    private func hasStandingInputGrant() -> Bool {
        if userDefaults.bool(forKey: Self.alwaysAllowPreferenceKey) {
            return true
        }
        guard let conversationID else { return false }
        return grantedConversationIDs.contains(conversationID)
    }

    private func record(_ scope: ComputerUseConsentScope) {
        switch scope {
        case .once:
            break
        case .conversation:
            guard let conversationID else { return }
            grantedConversationIDs.insert(conversationID)
        case .always:
            userDefaults.set(true, forKey: Self.alwaysAllowPreferenceKey)
        }
    }

    private func resolvePendingRequest(approved: Bool) {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        pendingApprovalContinuation?.resume(returning: approved)
        pendingApprovalContinuation = nil
    }
}
