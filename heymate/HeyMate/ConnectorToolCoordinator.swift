//
//  ConnectorToolCoordinator.swift
//  HeyMate
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
    /// What the call does, one plain line per action ("Gmail: Fetch message
    /// by thread ID"). Empty falls back to the connector name alone.
    var actions: [String] = []
}

/// Turns a tool call into lines a person can read. Composio's
/// multi-execute meta-tool is the hard case: its outer name says nothing,
/// and the real work is the `tools` list inside its arguments.
enum ConnectorToolCallDescription {

    /// - Parameter appNames: Composio toolkit slug → display name, for the
    ///   apps this Mac has connected. Unknown prefixes fall back to the
    ///   slug's first word.
    static func actions(
        forToolNamed toolName: String,
        arguments: [String: Any],
        appNames: [String: String] = [:]
    ) -> [String] {
        let outerName = toolName.components(separatedBy: "__").last ?? toolName
        guard outerName.uppercased() == "COMPOSIO_MULTI_EXECUTE_TOOL" else {
            return [sentence(from: outerName)]
        }
        let tools = arguments["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let slug = (tool["tool_slug"] as? String)
                ?? (tool["tool_name"] as? String)
                ?? (tool["slug"] as? String),
                  !slug.isEmpty else { return nil }
            return describeComposioSlug(slug, appNames: appNames)
        }
    }

    /// `GITHUB_LIST_WORKFLOW_RUNS` → "GitHub: List workflow runs".
    static func describeComposioSlug(_ slug: String, appNames: [String: String]) -> String {
        let upperSlug = slug.uppercased()
        // Longest prefix first, so GOOGLE_CALENDAR wins over GOOGLE.
        let match = appNames
            .map { (prefix: $0.key.uppercased().replacingOccurrences(of: "-", with: "_") + "_", name: $0.value) }
            .filter { upperSlug.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
        if let match {
            return "\(match.name): \(sentence(from: String(slug.dropFirst(match.prefix.count))))"
        }
        let words = slug.split(separator: "_").map(String.init)
        guard words.count > 1 else { return sentence(from: slug) }
        return "\(words[0].capitalized): \(sentence(from: words.dropFirst().joined(separator: "_")))"
    }

    /// `FETCH_MESSAGE_BY_THREAD_ID` → "Fetch message by thread ID".
    static func sentence(from name: String) -> String {
        let words = ConnectorToolRisk.tokenize(name).map { $0 == "id" ? "ID" : $0 }
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
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
        guard !Task.isCancelled else { return false }
        pendingApprovalContinuation?.resume(returning: false)
        pendingApprovalContinuation = nil

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
