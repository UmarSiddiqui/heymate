import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentWorkResultsTests {
    private func run(owner: AgentChatOwner, workspace: URL, artifact: String, executor: HeadlessExecutor = .codex) -> AgentRun {
        var run = AgentRun.queued(id: UUID(), title: "Research page", prompt: "Build page", workspaceURL: workspace,
                                  executor: executor, origin: .sandbox, sessionIdentifier: "owned-session", chatOwner: owner)
        run.status = .succeeded
        run.privateFinalResult = AgentReceiptPrivacy.privateAnswer("Research preserved.\n<ARTIFACTS>\n\(artifact)\n</ARTIFACTS>")
        return run
    }

    @Test func ownedCompletedArtifactSurvivesStoreReloadAcrossProviders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("index.html")
        try "<html>Prior research</html>".write(to: file, atomically: true, encoding: .utf8)
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        let storeURL = directory.appendingPathComponent("runs.json")
        for executor in [HeadlessExecutor.codex, .claudeCode] {
            let store = FileAgentRunStore(fileURL: storeURL)
            let job = run(owner: owner, workspace: directory.appendingPathComponent("other-workspace"), artifact: file.path, executor: executor)
            store.upsert(job)
            let owned = AgentWorkResults.ownedRuns(FileAgentRunStore(fileURL: storeURL).loadAll(), owner: owner)
            #expect(AgentWorkResults.artifact(in: owned, runID: job.id.uuidString, path: file.path) == file)
            #expect(AgentWorkResults.report(owned, includeContents: true).contains("Prior research"))
            #expect(AgentWorkResults.report(owned).contains(file.path))
        }
    }

    @Test func anotherChatSameMateAndAnotherMateSameChatCannotReadArtifacts() {
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        let directory = URL(fileURLWithPath: "/not-created")
        let job = run(owner: owner, workspace: directory, artifact: "index.html")
        #expect(AgentWorkResults.ownedRuns([job], owner: AgentChatOwner(mateID: owner.mateID, chatID: UUID())).isEmpty)
        #expect(AgentWorkResults.ownedRuns([job], owner: AgentChatOwner(mateID: UUID(), chatID: owner.chatID)).isEmpty)
        #expect(AgentWorkResults.artifact(in: [job], runID: nil, path: "/unowned.html") == nil)
    }

    @Test func delegatedResultIsAvailableOnlyToItsExplicitRequester() {
        let requester = AgentChatOwner(mateID: UUID(), chatID: UUID())
        var specialist = AgentChatOwner(mateID: UUID(), chatID: UUID())
        specialist.requestingMateID = requester.mateID
        specialist.requestingChatID = requester.chatID
        let job = run(owner: specialist, workspace: URL(fileURLWithPath: "/missing"), artifact: "index.html")
        #expect(AgentWorkResults.ownedRuns([job], owner: requester).map(\.id) == [job.id])
        #expect(AgentWorkResults.ownedRuns([job], owner: AgentChatOwner(mateID: requester.mateID, chatID: UUID())).isEmpty)
        let privateJob = run(owner: AgentChatOwner(mateID: specialist.mateID, chatID: specialist.chatID),
                             workspace: URL(fileURLWithPath: "/missing"), artifact: "private.html")
        #expect(AgentWorkResults.ownedRuns([privateJob], owner: requester).isEmpty)
    }

    @Test func relativePathsResolveAgainstRunWorkspaceAndMissingFilesStayMissing() {
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        let directory = URL(fileURLWithPath: "/missing-\(UUID().uuidString)")
        let job = run(owner: owner, workspace: directory, artifact: "index.html")
        let url = AgentWorkResults.artifact(in: [job], runID: nil, path: nil)!
        #expect(url.path == directory.appendingPathComponent("index.html").path)
        #expect(!AgentWorkResults.verifiedFile(url))
        #expect(AgentWorkResults.report([job]).contains("missing or unreadable"))
        #expect(AgentWorkResults.artifactURLs(in: run(owner: owner, workspace: directory, artifact: "../secret")).isEmpty)
    }

    @Test func failedRevisionRetainsPreviousArtifactAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("index.html")
        try "Preserved research".write(to: file, atomically: true, encoding: .utf8)
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        var job = run(owner: owner, workspace: directory, artifact: file.path)
        job.privateArtifactPaths = AgentWorkResults.artifactURLs(in: job).map(\.path)
        job.privateFinalResult = "Revision stopped because opening failed."
        job.status = .failed
        let storeURL = directory.appendingPathComponent("runs.json")
        FileAgentRunStore(fileURL: storeURL).upsert(job)
        let reloaded = AgentWorkResults.ownedRuns(FileAgentRunStore(fileURL: storeURL).loadAll(), owner: owner)
        #expect(AgentWorkResults.artifact(in: reloaded, runID: job.id.uuidString, path: file.path) == file)
        #expect(AgentWorkResults.report(reloaded, includeContents: true).contains("Preserved research"))
    }

    @Test func privateArtifactReferenceSurvivesWhileReceiptAndProseStayRedacted() {
        let raw = "Output /Users/example/private.txt\n<ARTIFACTS>\n/Users/example/page/index.html\n</ARTIFACTS>"
        let answer = AgentReceiptPrivacy.privateAnswer(raw)
        #expect(!answer.contains("/Users/example/private.txt"))
        #expect(answer.contains("/Users/example/page/index.html"))
        #expect(!AgentReceiptPrivacy.safeResult(answer).contains("/Users/example"))
    }

    @Test func harnessArtifactToolsWorkWithNativeAndTextualProviders() {
        for name in [HarnessToolName.inspectWork, .openArtifact, .revealArtifact] {
            #expect(HarnessToolRequestParser.parse("\(name.rawValue) {\"path\":\"/tmp/index.html\"}")?.name == name)
            #expect(HarnessToolRequestParser.parse("{\"tool\":\"\(name.rawValue)\"}")?.name == name)
        }
    }
}

@MainActor
struct ArtifactPresentationRegressionTests {
    @Test func openFailureAndMissingFileNeverReportSuccessOrLaunchUnownedPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("index.html")
        try "Original research".write(to: file, atomically: true, encoding: .utf8)
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        var job = AgentRun.queued(id: UUID(), title: "Page", prompt: "Page", workspaceURL: directory,
                                  executor: .codex, origin: .sandbox, sessionIdentifier: "same-session", chatOwner: owner)
        job.status = .succeeded
        job.privateFinalResult = "<ARTIFACTS>\nindex.html\n</ARTIFACTS>"
        var opened: [URL] = []
        var revealed: [URL] = []
        let failure = AgentWorkResults.presentArtifact(in: [job], runID: nil, path: file.path, reveal: false,
                                                       open: { opened.append($0); return false }, revealFile: { revealed.append($0) })
        #expect(failure.isError)
        #expect(failure.text == "macOS could not open: \(file.path)")
        let reveal = AgentWorkResults.presentArtifact(in: [job], runID: nil, path: file.path, reveal: true,
                                                      open: { _ in Issue.record("Reveal must not open"); return true }, revealFile: { revealed.append($0) })
        #expect(!reveal.isError)
        #expect(revealed == [file])
        try FileManager.default.removeItem(at: file)
        let missing = AgentWorkResults.presentArtifact(in: [job], runID: nil, path: file.path, reveal: false,
                                                       open: { opened.append($0); return true }, revealFile: { _ in })
        #expect(missing.isError)
        #expect(opened == [file])
        #expect(AgentWorkResults.continuableRun(in: [job], runID: job.id.uuidString)?.sessionIdentifier == "same-session")
        #expect(AgentWorkResults.continuableRun(in: [job], runID: UUID().uuidString) == nil)
    }
}

@MainActor
struct ArtifactApprovalPrivacyTests {
    @Test func privateApprovalKeepsCommandPathButRedactsSecrets() {
        let details = AgentReceiptPrivacy.privateToolDetails("mkdir /Users/example/deliverable; api_key=sk-test-secret")
        #expect(details.contains("/Users/example/deliverable"))
        #expect(!details.contains("sk-test-secret"))
    }
}

struct ScopedTalkRouteTests {
    @Test func talkToolsRequireCapabilityAndBridgeAuthentication() {
        #expect(LocalControlRouter.route(method: "POST", path: "/talk/tools", json: [:]) ==
                .rejected(statusCode: 403, message: "Missing conversation scope"))
        let route = LocalControlRouter.route(method: "POST", path: "/talk/call",
                                             json: ["scope": "opaque", "tool": "inspect_work", "arguments": "{}"])
        #expect(route == .accepted(.callTalkTool(scope: "opaque", name: "inspect_work", argumentsJSON: "{}")))
        #expect(LocalControlCommand.listTalkTools(scope: "opaque").touchesConnectedAccounts)
        #expect(LocalControlCommand.callTalkTool(scope: "opaque", name: "inspect_work", argumentsJSON: "{}").touchesConnectedAccounts)
    }
}
