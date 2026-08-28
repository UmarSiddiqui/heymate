//
//  DictationInserter.swift
//  leanring-buddy
//
//  FR-6 — Delivers finalized dictation text into whatever text field currently
//  holds keyboard focus, using a strict priority ladder:
//
//    1. Accessibility API selected-text replacement (most precise, leaves the
//       user's clipboard completely untouched).
//    2. Pasteboard handoff + synthetic Cmd+V (works almost everywhere; the
//       clipboard is snapshotted before and restored after).
//    3. Typed keystroke synthesis (final fallback): one synthetic keyDown/
//       keyUp pair per character carrying its own Unicode payload. Kept last
//       deliberately — it is the slowest rung (~6 ms per character), sensitive
//       to locale/keyboard-layout quirks, and cannot convey long text as
//       reliably as a paste can.
//
//  Hard safety rule: NEVER mutate a secure/password field. The security gate
//  always runs before any mutation is attempted, and if the focused field
//  cannot be identified well enough to judge it, we fail closed.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// Everything learnable about the field that currently has keyboard focus.
/// Used for logging, security heuristics, and debugging output.
struct FocusedFieldInfo: Equatable {
    let bundleIdentifier: String?
    let appName: String?
    let role: String?
    let subrole: String?
    let placeholder: String?
    /// Bounded preview of the field's current value (first 200 chars) when readable.
    let currentValuePreview: String?
}

/// Result of attempting to deliver dictation text into the focused field.
enum InsertionOutcome: Equatable {
    case insertedViaAccessibility
    case insertedViaPasteboard
    case insertedViaTyping
    case blockedSecureField
    case unsupportedPath(String)   // e.g. keystroke event creation refused on every rung
    case failed(String)
}

/// Heuristics for recognizing password/secure text fields before touching them.
enum DictationFieldSecurity {

    /// Heuristic: treat as secure when role OR subrole mentions "secure"
    /// (case-insensitive). Pure function, nonisolated, unit-testable.
    ///
    /// Why substring matching instead of an exhaustive list of known roles:
    /// secure text entry shows up under several spellings across frameworks
    /// (for example "AXSecureTextField", or subrole "SecureTextField"), and a
    /// substring scan stays safe against variants we have not seen yet. The
    /// cost asymmetry favors over-blocking: a false positive merely skips
    /// insertion into an oddly-named field, while a false negative would leak
    /// dictated text into a password box.
    nonisolated static func isLikelySecure(role: String?, subrole: String?) -> Bool {
        if let role, role.lowercased().contains("secure") { return true }
        if let subrole, subrole.lowercased().contains("secure") { return true }
        return false
    }
}

/// Inserts finalized dictation text into whatever text field has keyboard focus.
enum DictationInserter {

    // MARK: - Public API

    /// Reads frontmost app + AX focused element metadata. Returns nil when
    /// nothing resolvable (no Accessibility permission, no focused element).
    @MainActor
    static func focusedFieldMetadata() -> FocusedFieldInfo? {
        resolveFocusedElement()?.info
    }

    /// Inserts text using the priority ladder documented at the top of this
    /// file. Never throws.
    @MainActor
    static func insert(_ text: String) async -> InsertionOutcome {
        // Empty text would degenerate into "wipe the selection" (priority 1)
        // or "paste nothing while clobbering the clipboard" (priority 2), so it
        // is rejected before anything else happens.
        guard !text.isEmpty else { return .failed("empty text") }

        // Fail closed: without a resolvable focused element we cannot run the
        // secure-field gate, and blindly synthesizing a paste toward an unknown
        // target could leak dictation into a password box.
        guard let focus = resolveFocusedElement() else {
            print("⚠️ DictationInserter: no resolvable focused element (Accessibility permission or focus missing)")
            return .failed("no resolvable focused field")
        }

        // Security gate — ALWAYS before any mutation.
        if DictationFieldSecurity.isLikelySecure(role: focus.info.role, subrole: focus.info.subrole) {
            print("⚠️ DictationInserter: blocked insertion into likely-secure field in \(focus.info.appName ?? "unknown app")")
            return .blockedSecureField
        }

        // --- Priority 1: Accessibility selected-text replacement -------------
        if setSelectedText(on: focus.element, to: text) == .success {
            return .insertedViaAccessibility
        }
        // Any AX refusal (attribute unsupported, app busy, …) simply drops us
        // one rung down the ladder; nothing was mutated on this path.

        // --- Priority 2: Pasteboard + synthetic Cmd+V -------------------------
        if await insertViaPasteboard(text) {
            return .insertedViaPasteboard
        }

        // --- Priority 3: Typed keystrokes --------------------------------------
        // Last resort: typing is the slowest rung (~6 ms per character),
        // locale/keyboard-layout sensitive, and unreliable for long text — but
        // unlike the rungs above it needs neither AX text support nor a
        // cooperative clipboard.
        if await insertViaTyping(text) {
            return .insertedViaTyping
        }

        // Every rung refused. `.unsupportedPath` is reserved for the one
        // irreducible failure mode left now that typing exists: CGEvent
        // creation itself being refused (reported as false by insertViaTyping).
        return .unsupportedPath("all insertion rungs failed — synthetic event creation unavailable")
    }

    // MARK: - Focus resolution

    private struct ResolvedFocus {
        let element: AXUIElement
        let info: FocusedFieldInfo
    }

    @MainActor
    private static func resolveFocusedElement() -> ResolvedFocus? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedBox: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedBox
        )
        guard copyResult == .success, let boxedFocusedElement = focusedBox else { return nil }
        // The AX API returns an untyped CF object; for this attribute it is
        // always an AXUIElement.
        let focusedElement = boxedFocusedElement as! AXUIElement

        return ResolvedFocus(
            element: focusedElement,
            info: FocusedFieldInfo(
                bundleIdentifier: frontmostApplication.bundleIdentifier,
                appName: frontmostApplication.localizedName,
                role: stringValue(of: focusedElement, attribute: kAXRoleAttribute),
                subrole: stringValue(of: focusedElement, attribute: kAXSubroleAttribute),
                placeholder: stringValue(of: focusedElement, attribute: kAXPlaceholderValueAttribute),
                currentValuePreview: stringValue(of: focusedElement, attribute: kAXValueAttribute)
                    .map { String($0.prefix(currentValuePreviewCharacterLimit)) }
            )
        )
    }

    /// AX reads are thread-safe pure queries, so this helper deliberately stays
    /// usable from any isolation domain.
    private nonisolated static func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var boxedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &boxedValue)
        guard result == .success, let value = boxedValue as? String else { return nil }
        return value
    }

    // MARK: - Priority 1: Accessibility selected-text set

    /// Replaces the current selection via the Accessibility API. Returns the
    /// raw AXError so the caller can decide whether the failure is benign
    /// ("this field does not expose selectable text" → fall down the ladder).
    @MainActor
    private static func setSelectedText(on element: AXUIElement, to text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }

    // MARK: - Priority 2: Pasteboard + synthetic Cmd+V

    /// Puts `text` on the pasteboard, synthesizes Cmd+V toward the frontmost
    /// app, waits for the paste to be consumed, then restores the user's
    /// original clipboard contents. Returns false only when the synthetic
    /// events could not even be created.
    @MainActor
    private static func insertViaPasteboard(_ text: String) async -> Bool {
        let snapshotOfOriginalClipboard = ClipboardSnapshot.save()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Virtual key code 9 is the letter "V"; paired with the command flag
        // this produces a faithful Cmd+V press. A nil event source is the
        // conventional choice for one-shot synthetic events.
        guard let commandVKeyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCodeForLetterV, keyDown: true),
              let commandVKeyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCodeForLetterV, keyDown: false)
        else {
            print("⚠️ DictationInserter: could not synthesize Cmd+V events for pasteboard insertion")
            ClipboardSnapshot.restore(snapshotOfOriginalClipboard)
            return false
        }

        commandVKeyDown.flags = .maskCommand
        commandVKeyUp.flags = .maskCommand
        commandVKeyDown.post(tap: .cghidEventTap)
        commandVKeyUp.post(tap: .cghidEventTap)

        // Wait for the target app to consume the paste BEFORE restoring the
        // clipboard — restoring too early races the app's pasteboard read and
        // can end up pasting the user's previous clipboard content instead.
        // Task.sleep suspends rather than blocks, keeping the main actor free.
        // `try?` is deliberate: even a cancelled task must still reach the
        // clipboard restore below.
        _ = try? await Task.sleep(nanoseconds: pasteConsumptionDelayNanoseconds)

        ClipboardSnapshot.restore(snapshotOfOriginalClipboard)
        return true
    }

    // MARK: - Priority 3: Typed keystrokes

    /// Types `text` by synthesizing one keyDown/keyUp pair per character,
    /// attaching the character's UTF-16 payload via `keyboardSetUnicodeString`
    /// so no keyboard layout ever has to be consulted. Returns false
    /// immediately when an event cannot be created (the only way this rung
    /// fails); true once every keystroke has been posted.
    @MainActor
    private static func insertViaTyping(_ text: String) async -> Bool {
        // Iterate Swift Characters (not UTF-16 units) so surrogate pairs stay
        // inside a single event's payload.
        for character in text {
            var characterCodeUnits = Array(String(character).utf16)

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCodeForUnicodeTyping, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCodeForUnicodeTyping, keyDown: false)
            else {
                print("⚠️ DictationInserter: could not synthesize keystroke events for typed insertion")
                return false
            }

            // The Unicode payload rides on the keyDown — that is the event the
            // receiving app turns into text; the keyUp merely ends the press.
            keyDown.keyboardSetUnicodeString(stringLength: characterCodeUnits.count, unicodeString: &characterCodeUnits)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Pace the stream so the receiving app drains each keystroke
            // before the next arrives. `try?` mirrors the pasteboard path:
            // even a cancelled task must finish typing what was promised
            // rather than leave half the text behind.
            _ = try? await Task.sleep(nanoseconds: interKeystrokeDelayNanoseconds)
        }
        return true
    }

    // MARK: - Constants

    private static let currentValuePreviewCharacterLimit = 200
    /// ANSI virtual key code for the letter "V".
    private static let virtualKeyCodeForLetterV: CGKeyCode = 9
    /// Placeholder ANSI keycode carried by synthesized typing events; the
    /// attached Unicode string payload supersedes keycode interpretation, so
    /// the value itself is irrelevant.
    private static let virtualKeyCodeForUnicodeTyping: CGKeyCode = 0
    /// How long dictation text stays on the pasteboard before the user's
    /// original clipboard is restored.
    private static let pasteConsumptionDelayNanoseconds: UInt64 = 350_000_000
    /// Pause between synthesized keystrokes so the receiving app can drain
    /// each event before the next arrives (~6 ms per character).
    private static let interKeystrokeDelayNanoseconds: UInt64 = 6_000_000
}

/// Tiny save/restore wrapper around the shared pasteboard so the insertion
/// logic above reads as a straight line.
private enum ClipboardSnapshot {

    struct Content {
        let string: String?
        let changeCount: Int
    }

    /// Snapshots the pasteboard's string payload and its change count.
    /// Only the string payload is captured on purpose: dictation insertion
    /// rarely overlaps with meaningful rich clipboard content, and full
    /// multi-type snapshots add complexity for little benefit here.
    static func save() -> Content {
        let pasteboard = NSPasteboard.general
        return Content(
            string: pasteboard.string(forType: .string),
            changeCount: pasteboard.changeCount
        )
    }

    /// Writes the saved payload back onto the pasteboard. Exact changeCount
    /// restoration is impossible through public API (the counter is read-only
    /// and increments on every write); rewriting the contents at least leaves
    /// undo history and pasteboard observers in a sane state.
    static func restore(_ content: Content) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let restoredString = content.string {
            pasteboard.setString(restoredString, forType: .string)
        }
    }
}
