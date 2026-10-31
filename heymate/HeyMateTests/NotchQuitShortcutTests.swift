import AppKit
import Testing
@testable import HeyMate

@MainActor
struct NotchQuitShortcutTests {
    private func key(_ characters: String = "q", modifiers: NSEvent.ModifierFlags = .command,
                     repeats: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeats, keyCode: 12
        ))
    }

    private func panel() -> KeyableNotchPanel {
        KeyableNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
    }

    @Test func commandQRequestsQuitWithoutAnActiveAppMenu() throws {
        let panel = panel()
        var requests = 0
        panel.onQuitRequested = { requests += 1 }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(panel.performKeyEquivalent(with: try key()))
        #expect(requests == 1)
    }

    @Test func capsLockStillQuitsButHoldingQDoesNotRepeatQuit() throws {
        let panel = panel()
        var requests = 0
        panel.onQuitRequested = { requests += 1 }
        #expect(panel.performKeyEquivalent(with: try key("Q", modifiers: [.command, .capsLock])))
        #expect(panel.performKeyEquivalent(with: try key(repeats: true)))
        #expect(requests == 1)
    }

    @Test func typingAndOtherCommandChordsDoNotQuit() throws {
        let panel = panel()
        var requests = 0
        panel.onQuitRequested = { requests += 1 }
        let chords: [NSEvent.ModifierFlags] = [[], .control, [.command, .option],
                                             [.command, .control], [.command, .shift]]
        for modifiers in chords {
            _ = panel.performKeyEquivalent(with: try key(modifiers: modifiers))
        }
        _ = panel.performKeyEquivalent(with: try key("w"))
        #expect(requests == 0)
    }
}
