import AppKit

/// Takes keyboard focus without activating HeyMate or replacing the user's
/// menu bar. Such panels must handle Quit themselves: the active app's menu
/// does not reliably dispatch HeyMate's Command-Q action.
@MainActor
final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var onQuitRequested: () -> Void = { NSApp.terminate(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown,
              modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "q" else {
            return super.performKeyEquivalent(with: event)
        }
        // Keep the normal termination delegate and its active-work checks.
        // Holding Q must not open repeated warnings if termination is refused.
        if !event.isARepeat { onQuitRequested() }
        return true
    }
}
