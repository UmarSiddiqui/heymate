import Foundation
import Testing
@testable import HeyMate

struct MateFaceReactionTests {
    @Test func everyReactionSettlesBackToRest() {
        for reaction in MateFaceReaction.allCases {
            #expect(MateReactionPose.sample(reaction, elapsed: 0) == MateReactionPose() || reaction == .giggle,
                    "\(reaction) should start from the resting pose")
            #expect(MateReactionPose.sample(reaction, elapsed: reaction.duration) == MateReactionPose())
            #expect(MateReactionPose.sample(reaction, elapsed: .nan) == MateReactionPose())
            #expect(MateReactionPose.sample(reaction, elapsed: -1) == MateReactionPose())
        }
        #expect(MateReactionPose.sample(nil, elapsed: 0.3) == MateReactionPose())
    }

    @Test func reactionsMoveTheFaceMidway() {
        #expect(MateReactionPose.sample(.wink, elapsed: 0.3).rightEyeOpen < 0.2)
        #expect(MateReactionPose.sample(.wink, elapsed: 0.3).leftEyeOpen == 1)
        #expect(MateReactionPose.sample(.boop, elapsed: 0.19).squashY < 1)
        #expect(MateReactionPose.sample(.celebrate, elapsed: 0.46).lift < -0.05)
        #expect(MateReactionPose.sample(.wobble, elapsed: 0.08).tilt != 0)
    }

    @Test func tapsPickAReactionByPlace() {
        #expect(MateFaceReaction.forTap(count: 2, normalizedY: 0.2) == .giggle)
        #expect(MateFaceReaction.forTap(count: 1, normalizedY: 0.2) == .wink)
        #expect(MateFaceReaction.forTap(count: 1, normalizedY: 0.8) == .boop)
        #expect(MateFaceReaction.forFinished(.succeeded) == .celebrate)
        #expect(MateFaceReaction.forFinished(.failed) == .wobble)
        #expect(MateFaceReaction.forFinished(.cancelled) == nil)
    }

    @Test func hiddenFaceHoldsAReactionForTwoSeconds() {
        let start = Date()
        var inbox = MateReactionInbox()
        let event = MateReactionEvent(id: "run-1", reaction: .celebrate)
        let offered = inbox.offer(event, at: start)
        #expect(offered)
        let result1 = inbox.take(isVisible: false, at: start.addingTimeInterval(1))
        #expect(result1 == nil)
        let result2 = inbox.take(isVisible: true, at: start.addingTimeInterval(1.5))
        #expect(result2 == .celebrate)
        // Plays once.
        let result3 = inbox.take(isVisible: true, at: start.addingTimeInterval(1.6))
        #expect(result3 == nil)
    }

    @Test func staleOrRepeatedReactionsAreDropped() {
        let start = Date()
        var inbox = MateReactionInbox()
        let event = MateReactionEvent(id: "run-1", reaction: .wobble)
        inbox.offer(event, at: start)
        let result4 = inbox.take(isVisible: true, at: start.addingTimeInterval(2.5))
        #expect(result4 == nil)
        // The same id never comes back or extends the deadline.
        let result5 = inbox.offer(event, at: start.addingTimeInterval(3))
        #expect(!result5)
        let result6 = inbox.take(isVisible: true, at: start.addingTimeInterval(3))
        #expect(result6 == nil)
    }

    @Test func runningJobsShowWhatTheyAreDoing() {
        #expect(MateWorkActivity.expression(for: "Reading README.md") == .reading)
        #expect(MateWorkActivity.expression(for: "Editing Sources/App.swift") == .writing)
        #expect(MateWorkActivity.expression(for: "Running npm test") == .tooling)
        #expect(MateWorkActivity.expression(for: "Searching the web for flights") == .browsing)
        #expect(MateWorkActivity.expression(for: "Thinking about the plan") == .thinking)
        #expect(MateWorkActivity.expression(for: "") == .thinking)
        // Whole-word prefixes: "thread" is not "read".
        #expect(MateWorkActivity.expression(for: "Summarising the thread") == .thinking)
        #expect(MateFaceExpression.reading.isWorking)
        #expect(!MateFaceExpression.idle.isWorking)
    }
}
