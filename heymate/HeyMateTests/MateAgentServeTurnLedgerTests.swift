import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateAgentServeTurnLedgerTests {
    @Test func pendingStartCursorAndAcceptanceSurviveReopen() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let pending = try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        try fixture.ledger.markAccepted(chatID: fixture.chat, profile: fixture.profile, userRowID: 42)
        let record = try fixture.ledger.record(chatID: fixture.chat, profile: fixture.profile)
        #expect(record.pending?.id == pending.id)
        #expect(record.pending?.accepted == true)
        #expect(record.pending?.userRowID == 42)
        #expect(record.pending?.startCheckpoint == fixture.checkpoint)
        #expect(record.checkpoint == fixture.checkpoint)
        #expect(record.deliveries.isEmpty)
    }

    @Test func terminalResultAndDeliveryKeyCommitBeforePendingIsCleared() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let pending = try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        let end = MateAgentServeSession.Checkpoint(identity: fixture.checkpoint.identity, epoch: "test-epoch", lastSequence: 15)
        let delivery = try fixture.ledger.complete(chatID: fixture.chat, profile: fixture.profile,
            result: .init(text: "Verified private result", status: "complete", completionSequence: 15), checkpoint: end)
        #expect(delivery.id == pending.id)
        #expect(delivery.key == "pi-sessions:\(pending.id.uuidString)")
        let record = try fixture.ledger.record(chatID: fixture.chat, profile: fixture.profile)
        #expect(record.pending == nil)
        #expect(record.checkpoint == end)
        #expect(record.deliveries == [delivery])
        try fixture.ledger.markDelivered(delivery.id, chatID: fixture.chat, profile: fixture.profile)
        let delivered = try fixture.ledger.record(chatID: fixture.chat, profile: fixture.profile).deliveries
        #expect(delivered.first?.delivered == true)
        #expect(delivered.first?.text == "")
    }

    @Test func anotherPendingTurnCannotOverwriteUncertainSubmission() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        #expect(throws: MateAgentServeTurnLedger.Failure.self) {
            try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        }
        #expect(try fixture.ledger.record(chatID: fixture.chat, profile: fixture.profile).pending?.id == first.id)
    }

    @Test func corruptLedgerIsPreservedAndBlocksReplacementWork() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        let file = fixture.root.appendingPathComponent("turn-ledger.json")
        let corrupt = Data("{broken recovery ledger".utf8)
        try corrupt.write(to: file)
        #expect(throws: MateAgentServeTurnLedger.Failure.self) { try fixture.ledger.record(chatID: fixture.chat, profile: fixture.profile) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func chatsAndProfilesHaveIndependentPendingOwners() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.ledger.begin(chatID: fixture.chat, profile: fixture.profile, checkpoint: fixture.checkpoint)
        #expect(try fixture.ledger.record(chatID: UUID(), profile: fixture.profile).pending == nil)
        #expect(try fixture.ledger.record(chatID: fixture.chat, profile: fixture.root.appendingPathComponent("other-profile")).pending == nil)
        let file = fixture.root.appendingPathComponent("turn-ledger.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @MainActor
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mateAgent-ledger-\(UUID())", isDirectory: true)
        let chat = UUID()
        var profile: URL { root.appendingPathComponent("profile", isDirectory: true) }
        var ledger: MateAgentServeTurnLedger { MateAgentServeTurnLedger(root: root) }
        var checkpoint: MateAgentServeSession.Checkpoint {
            .init(identity: .init(runtimeID: "runtime-session", storedID: "stored-session"), epoch: "test-epoch", lastSequence: 3)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
