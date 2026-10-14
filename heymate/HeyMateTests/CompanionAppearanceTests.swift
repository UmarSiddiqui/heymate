import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CompanionAppearanceTests {
    @Test func floatingChatRoutingHonorsTheOwnedSessionAndRejectsMismatchedHistory() {
        let mate = Mate(id: UUID(), name: "Builder", job: "Build", pinned: false, archived: false,
                        unreadCount: 0, createdAt: .distantPast, updatedAt: .distantPast, memoryNote: "")
        var owned = ChatSession.empty()
        owned.mateID = mate.id
        var current = ChatSession.empty()
        current.mateID = mate.id
        var run = AgentRun.queued(id: UUID(), title: "Work", prompt: "",
                                 workspaceURL: URL(fileURLWithPath: "/tmp/owned-chat-test"),
                                 executor: .openCode, origin: .sandbox)
        run.chatOwner = AgentChatOwner(mateID: mate.id, chatID: owned.id)
        #expect(FloatingAgentPresentation.ownedChatID(for: run, mate: mate, currentChat: current,
                                                     storedChat: owned, defaultMateID: UUID()) == owned.id)
        owned.mateID = UUID()
        #expect(FloatingAgentPresentation.ownedChatID(for: run, mate: mate, currentChat: current,
                                                     storedChat: owned, defaultMateID: mate.id) == nil)
        run.chatOwner = AgentChatOwner(mateID: mate.id, chatID: current.id)
        #expect(FloatingAgentPresentation.ownedChatID(for: run, mate: mate, currentChat: current,
                                                     storedChat: nil, defaultMateID: UUID()) == current.id)
    }

    @Test func catalogArtworkPosesStayBoundedAndStaticRenderingStaysNeutral() {
        let expressions: [MateFaceExpression] = [.still, .idle, .listening, .thinking, .speaking,
                                                .attention, .success, .failure, .guiding]
        for asset in MateFace.assetNames {
            for expression in expressions {
                #expect(MateArtworkPose.sample(assetName: asset, expression: expression, elapsed: 0) == MateArtworkPose())
                for step in 1...120 {
                    let pose = MateArtworkPose.sample(assetName: asset, expression: expression, elapsed: Double(step) / 24)
                    #expect(abs(pose.rotation) <= 5)
                    #expect(abs(pose.lift) <= 0.05)
                    #expect((0.98...1.02).contains(pose.scale))
                    if expression == .still { #expect(pose == MateArtworkPose()) }
                }
            }
        }
        #expect(MateArtworkPose.sample(assetName: "MateFaceMarginBoat", expression: .idle, elapsed: .nan) == MateArtworkPose())
    }

    @Test func systemReduceMotionWinsForEveryCharacterState() {
        let policy = CompanionMotionPolicy(reduceMotion: true, idleAnimations: true, isVisible: true)
        #expect(!policy.allowsTransitions)
        #expect(!policy.allowsPlayback(isIdle: true))
        #expect(!policy.allowsPlayback(isIdle: false))
    }

    @Test func hiddenCharactersNeverSchedulePlayback() {
        let policy = CompanionMotionPolicy(reduceMotion: false, idleAnimations: true, isVisible: false)
        #expect(!policy.allowsPlayback(isIdle: true))
        #expect(!policy.allowsPlayback(isIdle: false))
    }

    @Test func idlePreferenceDoesNotSilenceActiveFeedback() {
        let policy = CompanionMotionPolicy(reduceMotion: false, idleAnimations: false, isVisible: true)
        #expect(!policy.allowsPlayback(isIdle: true))
        #expect(policy.allowsPlayback(isIdle: false))
        #expect(policy.allowsTransitions)
    }

    @Test func attentionAndFailureStayDistinctFromSpeechAndIdle() {
        #expect(MateFaceExpression.live(.waitingForApproval(UUID())) == .attention)
        #expect(MateFaceExpression.live(.error("Offline")) == .failure)
        #expect(MateFaceExpression.live(.guiding) == .guiding)
        #expect(MateFaceExpression.live(.speaking) == .speaking)
        #expect(MateFaceExpression.agent(.awaitingPlanApproval) == .attention)
        #expect(MateFaceExpression.agent(.waitingForApproval) == .attention)
        #expect(MateFaceExpression.agent(.failed) == .failure)
        #expect(MateFaceExpression.agent(.succeeded) == .success)
        #expect(MateFaceExpression.agent(.cancelled) == .still)
    }

    @Test func floatingJobsPrioritizeApprovalAndExcludeFinishedHistory() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        func run(_ status: AgentRunStatus, offset: Double) -> AgentRun {
            var run = AgentRun.queued(id: UUID(), title: status.rawValue, prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/appearance-test"),
                                      executor: .openCode, origin: .sandbox, createdAt: date.addingTimeInterval(offset))
            run.status = status
            return run
        }
        let approval = run(.awaitingPlanApproval, offset: 0)
        let running = run(.running, offset: 3)
        let planning = run(.planning, offset: 2)
        let queued = run(.queued, offset: 1)
        let finished = run(.succeeded, offset: 4)
        #expect(FloatingAgentPresentation.activeRuns([queued, finished, running, planning, approval]).map(\.id)
                == [approval.id, running.id, planning.id])
        #expect(FloatingAgentPresentation.activeRuns([queued, finished, running, planning, approval], limit: nil).map(\.id)
                == [approval.id, running.id, planning.id, queued.id])
        #expect(FloatingAgentPresentation.activeRuns([finished]).isEmpty)
    }

    @Test func floatingPanelsStayInsideOffsetAndSmallDisplays() {
        for screen in [CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                       CGRect(x: 900, y: 1200, width: 200, height: 180)] {
            let panel = FloatingAgentPresentation.frame(visibleFrame: screen, height: 400)
            #expect(screen.contains(panel))
            #expect(panel.maxX <= screen.maxX - 12)
            #expect(panel.maxY <= screen.maxY - 16)
        }
    }
    @Test func completionReactionRequiresAnObservedOwnedTransition() {
        let owner = UUID()
        var run = AgentRun.queued(id: UUID(), title: "Own job", prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/reaction-test"),
                                  executor: .openCode, origin: .sandbox)
        run.chatOwner = AgentChatOwner(mateID: owner, chatID: UUID())
        run.status = .running
        var done = run
        done.status = .succeeded
        #expect(MateCompletionReaction.next(previous: [run], current: [done], mateID: owner)?.expression == .success)
        #expect(MateCompletionReaction.next(previous: [], current: [done], mateID: owner) == nil)
        #expect(MateCompletionReaction.next(previous: [done], current: [done], mateID: owner) == nil)
        #expect(MateCompletionReaction.next(previous: [run], current: [done], mateID: UUID()) == nil)
        done.status = .cancelled
        #expect(MateCompletionReaction.next(previous: [run], current: [done], mateID: owner) == nil)
        done.status = .failed
        #expect(MateCompletionReaction.next(previous: [run], current: [done], mateID: owner)?.expression == .failure)
    }

    @Test func floatingCardsResolveTheirOwnerWithoutGuessingAnotherMate() {
        var mate = Mate(id: UUID(), name: "Build mate", job: "Build", pinned: false,
                        archived: false, unreadCount: 0, createdAt: .distantPast,
                        updatedAt: .distantPast, memoryNote: "")
        mate.folderPath = "/tmp/owner-workspace"
        var run = AgentRun.queued(id: UUID(), title: "Own job", prompt: "",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/owner-workspace/"),
                                  executor: .openCode, origin: .sandbox)
        #expect(FloatingAgentPresentation.owner(for: run, mates: [mate])?.id == mate.id)
        run.chatOwner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        #expect(FloatingAgentPresentation.owner(for: run, mates: [mate]) == nil)
        run = AgentRun.queued(id: UUID(), title: "Other folder", prompt: "",
                              workspaceURL: URL(fileURLWithPath: "/tmp/other-workspace"),
                              executor: .openCode, origin: .sandbox)
        run.chatOwner = AgentChatOwner(mateID: mate.id, chatID: UUID())
        #expect(FloatingAgentPresentation.owner(for: run, mates: [mate])?.id == mate.id)
        run.chatOwner = nil
        #expect(FloatingAgentPresentation.owner(for: run, mates: [mate]) == nil)
    }

}
