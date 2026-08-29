//
//  DetachedAgentRunnerBootstrapTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRunnerBootstrapTests {
    @Test func invocationAcceptsOnlyFixedBootstrapDescriptor() throws {
        let runID = UUID()
        let attemptID = UUID()
        let valid = try #require(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "/Applications/HeyMate.app/Contents/MacOS/HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "3"
                ]
            )
        )

        #expect(valid.runID == runID)
        #expect(valid.attemptID == attemptID)
        #expect(valid.bootstrapFileDescriptor == 3)
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "9"
                ]
            ) == nil
        )
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "3",
                    "unexpected"
                ]
            ) == nil
        )
    }

    @Test func invocationRejectsMissingOrMalformedIdentifiers() {
        #expect(DetachedAgentRunnerInvocation(arguments: ["HeyMate"]) == nil)
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    "not-a-run-id",
                    UUID().uuidString,
                    "3"
                ]
            ) == nil
        )
    }

    @Test func appEntrypointDetectsOnlyExactRunnerFlagArgument() {
        #expect(DetachedAgentRunnerInvocation.containsRunnerFlag(arguments: [
            "HeyMate",
            DetachedAgentRunnerInvocation.commandLineFlag
        ]))
        #expect(!DetachedAgentRunnerInvocation.containsRunnerFlag(arguments: [
            "HeyMate",
            "--prompt=--heymate-agent-runner"
        ]))
    }

    @Test func resolvesEmbeddedRunnerAtFixedHelpersPath() throws {
        let runnerURL = try #require(DetachedAgentRunnerExecutable.bundledURL())
        #expect(runnerURL.lastPathComponent == DetachedAgentRunnerExecutable.executableName)
        #expect(runnerURL.deletingLastPathComponent().lastPathComponent == "Helpers")
        #expect(runnerURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents")
        #expect(runnerURL != Bundle.main.executableURL)
        #expect(
            DetachedAgentRunnerExecutable.containingAppBundleURL(
                executableURL: runnerURL
            ) == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    @Test func fixedResolverRejectsSymlinkedRunner() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let appURL = fixtureURL.appendingPathComponent("Fake.app", isDirectory: true)
        let helpersURL = appURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        let outsideURL = fixtureURL.appendingPathComponent("outside-runner")
        try Data("#!/bin/sh\n".utf8).write(to: outsideURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outsideURL.path)
        try FileManager.default.createSymbolicLink(
            at: helpersURL.appendingPathComponent(DetachedAgentRunnerExecutable.executableName),
            withDestinationURL: outsideURL
        )

        #expect(DetachedAgentRunnerExecutable.bundledURL(bundleURL: appURL) == nil)
    }
}
