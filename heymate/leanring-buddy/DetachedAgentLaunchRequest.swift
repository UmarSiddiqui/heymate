//
//  DetachedAgentLaunchRequest.swift
//  leanring-buddy
//
//  One-leg bootstrap payload for signed embedded detached runner. This value
//  can contain prompts, CLI arguments, environment values, and session IDs.
//  It must travel only through the inherited bootstrap pipe; persistence APIs
//  deliberately do not accept it.
//

import Foundation

nonisolated enum DetachedAgentRunLegKind: String, Codable, Equatable, Sendable {
    case plan
    case execute
    case replan
    case followUp
}

nonisolated struct DetachedAgentLaunchSpec: Codable, Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environmentKeysToRemove: [String]
    let environmentOverrides: [String: String]
    let temporaryDirectoriesToRemove: [URL]
    let usesDuplexStandardInput: Bool
    let runtimeLimit: TimeInterval

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environmentKeysToRemove: [String] = [],
        environmentOverrides: [String: String] = [:],
        temporaryDirectoriesToRemove: [URL] = [],
        usesDuplexStandardInput: Bool = false,
        runtimeLimit: TimeInterval
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environmentKeysToRemove = environmentKeysToRemove
        self.environmentOverrides = environmentOverrides
        self.temporaryDirectoriesToRemove = temporaryDirectoriesToRemove
        self.usesDuplexStandardInput = usesDuplexStandardInput
        self.runtimeLimit = runtimeLimit
    }
}

nonisolated enum DetachedAgentLaunchRequestError: Error, Equatable {
    case payloadTooLarge(maximumBytes: Int)
    case truncatedFrame
    case invalidFrameLength(Int)
    case unsupportedSchemaVersion(Int)
    case runIDMismatch(expected: UUID, actual: UUID)
    case attemptIDMismatch(expected: UUID, actual: UUID)
    case invalidExecutablePath
    case invalidWorkingDirectory
    case invalidRuntimeLimit
}

nonisolated struct DetachedAgentLaunchRequest: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 4 * 1024 * 1024

    let schemaVersion: Int
    let runID: UUID
    let attemptID: UUID
    let executor: HeadlessExecutor
    let leg: DetachedAgentRunLegKind
    let createdAt: Date
    let spec: DetachedAgentLaunchSpec

    init(
        runID: UUID,
        attemptID: UUID,
        executor: HeadlessExecutor,
        leg: DetachedAgentRunLegKind,
        createdAt: Date = Date(),
        spec: DetachedAgentLaunchSpec
    ) {
        schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        self.runID = runID
        self.attemptID = attemptID
        self.executor = executor
        self.leg = leg
        self.createdAt = createdAt
        self.spec = spec
    }

    /// Writes one bounded, length-prefixed JSON frame to an inherited pipe or
    /// socketpair. No launch payload bytes are written to the filesystem.
    func write(to handle: FileHandle) throws {
        try validate()
        let payload = try Self.makeEncoder().encode(self)
        guard payload.count <= Self.maximumEncodedBytes else {
            throw DetachedAgentLaunchRequestError.payloadTooLarge(
                maximumBytes: Self.maximumEncodedBytes
            )
        }

        var bigEndianLength = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &bigEndianLength) { Data($0) }
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
    }

    /// Reads exactly one launch frame. Expected identifiers come from the
    /// runner's fixed argv and prevent a swapped bootstrap payload.
    static func read(
        from handle: FileHandle,
        expectedRunID: UUID,
        expectedAttemptID: UUID
    ) throws -> Self {
        let header = try readExactly(4, from: handle)
        guard header.count == 4 else {
            throw DetachedAgentLaunchRequestError.truncatedFrame
        }

        var bigEndianLength: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &bigEndianLength) { destination in
            header.copyBytes(to: destination)
        }
        let payloadLength = Int(UInt32(bigEndian: bigEndianLength))
        guard payloadLength > 0, payloadLength <= maximumEncodedBytes else {
            throw DetachedAgentLaunchRequestError.invalidFrameLength(payloadLength)
        }

        let payload = try readExactly(payloadLength, from: handle)
        guard payload.count == payloadLength else {
            throw DetachedAgentLaunchRequestError.truncatedFrame
        }
        let request = try makeDecoder().decode(Self.self, from: payload)
        guard request.schemaVersion == DetachedAgentRuntimeProtocol.currentSchemaVersion else {
            throw DetachedAgentLaunchRequestError.unsupportedSchemaVersion(request.schemaVersion)
        }
        guard request.runID == expectedRunID else {
            throw DetachedAgentLaunchRequestError.runIDMismatch(
                expected: expectedRunID,
                actual: request.runID
            )
        }
        guard request.attemptID == expectedAttemptID else {
            throw DetachedAgentLaunchRequestError.attemptIDMismatch(
                expected: expectedAttemptID,
                actual: request.attemptID
            )
        }
        try request.validate()
        return request
    }

    private func validate() throws {
        guard spec.executableURL.isFileURL, spec.executableURL.path.hasPrefix("/") else {
            throw DetachedAgentLaunchRequestError.invalidExecutablePath
        }
        guard spec.currentDirectoryURL.isFileURL,
              spec.currentDirectoryURL.path.hasPrefix("/") else {
            throw DetachedAgentLaunchRequestError.invalidWorkingDirectory
        }
        guard spec.runtimeLimit.isFinite, spec.runtimeLimit > 0 else {
            throw DetachedAgentLaunchRequestError.invalidRuntimeLimit
        }
    }

    private static func readExactly(_ byteCount: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            let remainingCount = byteCount - result.count
            guard let chunk = try handle.read(upToCount: remainingCount), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
