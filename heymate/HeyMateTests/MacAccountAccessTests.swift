import Foundation
import Testing
@testable import HeyMate

@Suite(.serialized)
@MainActor
struct MacAccountAccessTests {
    @Test func disabledNativeSourcesAreNeverRead() async {
        await withManager { manager in
            for id in ["apple-calendar", "apple-mail"] {
                manager.connectorStore.markConnected(connectorID: id, accountLabel: "fixture")
                manager.setChatConnectorEnabled(false, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: id))
            }
            let blocks = await manager.macAccountContextBlocks(for: "check my calendar and email", calendarReader: {
                Issue.record("Disabled calendar was read"); return "private calendar"
            }, mailReader: {
                Issue.record("Disabled mail was read"); return "private mail"
            })
            #expect(blocks.isEmpty)
        }
    }

    @Test func enabledConnectedSourceSuppliesItsActualContext() async {
        await withManager { manager in
            manager.connectorStore.markConnected(connectorID: "apple-mail", accountLabel: "fixture")
            manager.setChatConnectorEnabled(true, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-mail"))
            let blocks = await manager.macAccountContextBlocks(for: "check my email", mailReader: { "verified mail fixture" })
            #expect(blocks == ["verified mail fixture"])
        }
    }

    @Test func unreadableSourceIsNotReportedAsEmpty() async {
        await withManager { manager in
            manager.connectorStore.markConnected(connectorID: "apple-calendar", accountLabel: "fixture")
            manager.setChatConnectorEnabled(true, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-calendar"))
            let blocks = await manager.macAccountContextBlocks(for: "check my calendar", calendarReader: { nil })
            #expect(blocks.count == 1)
            #expect(blocks.first?.contains("does not mean it is empty") == true)
        }
    }

    @Test func disablingSourceDuringReadWithholdsItsContent() async {
        await withManager { manager in
            manager.connectorStore.markConnected(connectorID: "apple-mail", accountLabel: "fixture")
            let selection = CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-mail")
            manager.setChatConnectorEnabled(true, selectionID: selection)
            let gate = ContextReadGate()
            let read = Task { await manager.macAccountContextBlocks(for: "read my email", mailReader: { gate.read() }) }
            let started = await Task.detached { gate.started.wait(timeout: .now() + 3) == .success }.value
            #expect(started)
            manager.setChatConnectorEnabled(false, selectionID: selection)
            gate.resume.signal()
            #expect(await read.value == [])
        }
    }

    private func withManager(_ body: (CompanionManager) async -> Void) async {
        let defaults = UserDefaults.standard
        let records = defaults.object(forKey: ConnectorStore.recordsPreferenceKey)
        let exclusions = defaults.object(forKey: CompanionManager.chatConnectorExclusionsPreferenceKey)
        defer {
            defaults.set(records, forKey: ConnectorStore.recordsPreferenceKey)
            defaults.set(exclusions, forKey: CompanionManager.chatConnectorExclusionsPreferenceKey)
        }
        await body(CompanionManager())
    }
}

private final class ContextReadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func read() -> String? {
        started.signal()
        guard resume.wait(timeout: .now() + 3) == .success else { return nil }
        return "private context that must not reach the model"
    }
}
