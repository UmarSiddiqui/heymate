//
//  DetachedAgentRuntimeProtocol.swift
//  leanring-buddy
//
//  Stable, Codable messages shared by HeyMate and its detached runner.
//  Runtime messages may contain live output. Persistence deliberately uses
//  the narrower journal record in DetachedAgentRuntimePersistence.swift.
//

import Foundation

nonisolated enum DetachedAgentRuntimeProtocol {
    static let currentSchemaVersion = 1
}

nonisolated enum DetachedAgentRuntimePhase: String, Codable, Equatable, Sendable {
    case queued
    case launching
    case running
    case waitingForApproval
    case interrupting
    case detached
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .launching, .running, .waitingForApproval, .interrupting, .detached:
            return false
        }
    }
}

nonisolated enum DetachedAgentOutputStream: String, Codable, Equatable, Sendable {
    case standardOutput
    case standardError
}

/// Event sent from runner to app.
///
/// `text`, `sessionIdentifier`, and `approvalIdentifier` are transient IPC
/// values. They must not be written directly to disk. The runtime journal
/// converts this type to a persistence-safe record first.
nonisolated struct DetachedAgentRuntimeEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case ready
        case phaseChanged
        case progress
        case output
        case sessionIdentified
        case heartbeat
        case approvalRequested
        case finished
        case warning
    }

    let kind: Kind
    let phase: DetachedAgentRuntimePhase?
    let stream: DetachedAgentOutputStream?
    let text: String?
    let sessionIdentifier: String?
    let approvalIdentifier: String?
    let exitCode: Int32?

    private init(
        kind: Kind,
        phase: DetachedAgentRuntimePhase? = nil,
        stream: DetachedAgentOutputStream? = nil,
        text: String? = nil,
        sessionIdentifier: String? = nil,
        approvalIdentifier: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.stream = stream
        self.text = text
        self.sessionIdentifier = sessionIdentifier
        self.approvalIdentifier = approvalIdentifier
        self.exitCode = exitCode
    }

    static let ready = Self(kind: .ready)

    static func phaseChanged(_ phase: DetachedAgentRuntimePhase) -> Self {
        Self(kind: .phaseChanged, phase: phase)
    }

    static func progress(_ summary: String) -> Self {
        Self(kind: .progress, text: summary)
    }

    static func output(_ text: String, stream: DetachedAgentOutputStream) -> Self {
        Self(kind: .output, stream: stream, text: text)
    }

    static func sessionIdentified(_ identifier: String) -> Self {
        Self(kind: .sessionIdentified, sessionIdentifier: identifier)
    }

    static let heartbeat = Self(kind: .heartbeat)

    static func approvalRequested(identifier: String, summary: String) -> Self {
        Self(
            kind: .approvalRequested,
            text: summary,
            approvalIdentifier: identifier
        )
    }

    static func finished(
        phase: DetachedAgentRuntimePhase,
        exitCode: Int32?,
        summary: String? = nil
    ) -> Self {
        Self(kind: .finished, phase: phase, text: summary, exitCode: exitCode)
    }

    static func warning(_ summary: String) -> Self {
        Self(kind: .warning, text: summary)
    }
}

nonisolated struct DetachedAgentEventEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let messageID: UUID
    let emittedAt: Date
    let event: DetachedAgentRuntimeEvent

    init(
        runID: UUID,
        messageID: UUID = UUID(),
        emittedAt: Date = Date(),
        event: DetachedAgentRuntimeEvent
    ) {
        self.schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        self.runID = runID
        self.messageID = messageID
        self.emittedAt = emittedAt
        self.event = event
    }
}

/// Command sent from app to runner. Command payloads are transient and are
/// never accepted by the durable journal API.
nonisolated struct DetachedAgentRuntimeCommand: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case interrupt
        case cancel
        case requestSnapshot
        case detach
        case resume
        case takeOverInTerminal
        case sendFollowUp
        case respondToApproval
        case shutdown
    }

    enum ApprovalDecision: String, Codable, Equatable, Sendable {
        case approve
        case deny
    }

    let kind: Kind
    let text: String?
    let approvalIdentifier: String?
    let approvalDecision: ApprovalDecision?
    let afterSequence: UInt64?

    private init(
        kind: Kind,
        text: String? = nil,
        approvalIdentifier: String? = nil,
        approvalDecision: ApprovalDecision? = nil,
        afterSequence: UInt64? = nil
    ) {
        self.kind = kind
        self.text = text
        self.approvalIdentifier = approvalIdentifier
        self.approvalDecision = approvalDecision
        self.afterSequence = afterSequence
    }

    static let interrupt = Self(kind: .interrupt)
    static let cancel = Self(kind: .cancel)
    static let requestSnapshot = Self(kind: .requestSnapshot)
    static let detach = Self(kind: .detach)
    static let takeOverInTerminal = Self(kind: .takeOverInTerminal)
    static let shutdown = Self(kind: .shutdown)

    static func resume(afterSequence: UInt64?) -> Self {
        Self(kind: .resume, afterSequence: afterSequence)
    }

    static func sendFollowUp(_ text: String) -> Self {
        Self(kind: .sendFollowUp, text: text)
    }

    static func respondToApproval(
        identifier: String,
        decision: ApprovalDecision
    ) -> Self {
        Self(
            kind: .respondToApproval,
            approvalIdentifier: identifier,
            approvalDecision: decision
        )
    }
}

nonisolated struct DetachedAgentCommandEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let messageID: UUID
    let sentAt: Date
    let command: DetachedAgentRuntimeCommand

    init(
        runID: UUID,
        messageID: UUID = UUID(),
        sentAt: Date = Date(),
        command: DetachedAgentRuntimeCommand
    ) {
        self.schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        self.runID = runID
        self.messageID = messageID
        self.sentAt = sentAt
        self.command = command
    }
}
