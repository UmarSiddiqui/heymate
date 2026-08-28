import Foundation
import Testing
@testable import HeyMate

struct AgentFilamentTests {
    @Test func folderHueIsStableAndSlugSensitive() {
        let first = AgentFilament.stableHue(forFolderSlug: "landing-page")
        #expect(first == AgentFilament.stableHue(forFolderSlug: "landing-page"))
        #expect(first != AgentFilament.stableHue(forFolderSlug: "api-server"))
        #expect((0..<1).contains(first))
    }

    @Test func onlyLiveRunsBecomeFilaments() {
        let live = AgentRun.queued(
            id: UUID(),
            title: "live",
            prompt: "work",
            workspaceURL: URL(fileURLWithPath: "/tmp/live-folder", isDirectory: true),
            executor: .codex,
            origin: .sandbox
        )
        var done = AgentRun.queued(
            id: UUID(),
            title: "done",
            prompt: "work",
            workspaceURL: URL(fileURLWithPath: "/tmp/done-folder", isDirectory: true),
            executor: .codex,
            origin: .sandbox
        )
        done.status = .succeeded

        #expect(AgentFilament.live(from: [live, done]).map(\.id) == [live.id])
    }
}
