//
//  DetachedAgentRunnerInvocation.swift
//  HeyMate
//
//  Strict command-line contract shared by app bootstrap and embedded runner.
//

import Foundation

nonisolated struct DetachedAgentRunnerInvocation: Equatable, Sendable {
    static let commandLineFlag = "--heymate-agent-runner"
    static let inheritedBootstrapFileDescriptor: Int32 = 3

    let runID: UUID
    let attemptID: UUID
    let bootstrapFileDescriptor: Int32

    init?(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.count == 5,
              arguments[1] == Self.commandLineFlag,
              let runID = UUID(uuidString: arguments[2]),
              let attemptID = UUID(uuidString: arguments[3]),
              let bootstrapFileDescriptor = Int32(arguments[4]),
              bootstrapFileDescriptor == Self.inheritedBootstrapFileDescriptor else {
            return nil
        }
        self.runID = runID
        self.attemptID = attemptID
        self.bootstrapFileDescriptor = bootstrapFileDescriptor
    }

    static func containsRunnerFlag(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.dropFirst().contains(Self.commandLineFlag)
    }
}
