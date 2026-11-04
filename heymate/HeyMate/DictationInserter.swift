//
//  DictationInserter.swift
//  HeyMate
//
//  FR-6 — Delivers finalized dictation text into whatever text field currently
//  holds keyboard focus, using a strict priority ladder:
//
//    1. Pasteboard handoff + recipient-addressed Cmd+V, matching normal typing
//       and editor input events. The clipboard is restored afterward.
//    2. Accessibility selected-text replacement if keyboard posting is unavailable.
//    3. Typed keystroke synthesis (final fallback): one synthetic keyDown/
//       keyUp pair per character carrying its own Unicode payload. Kept last
//       deliberately — it is the slowest rung (~6 ms per character), sensitive
//       to locale/keyboard-layout quirks, and cannot convey long text as
//       reliably as a paste can.
//
//  Secure text fields and macOS Secure Event Input block insertion. If an app
//  does not expose AX focus, a user-started dictation can still use ordinary
//  paste, but only into the same app that received the shortcut.
//

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

nonisolated struct DictationInsertionTarget {
    let processIdentifier: pid_t
    let startedInSecureInput: Bool
}

nonisolated enum DictationPastePolicy {
    static func allowsUnexposedField(target: DictationInsertionTarget?, currentPID: pid_t?,
                                    secureInput: Bool, canPostEvents: Bool) -> Bool {
        guard let target, !target.startedInSecureInput, !secureInput, canPostEvents else { return false }
        return target.processIdentifier == currentPID
    }
}

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

/// Prefer the target app's focus; the system-wide proxy can be unavailable
/// or can briefly point at another process during a focus transition.
nonisolated enum DictationFocusLookup {
    static func resolve<Element>(application: () -> Element?, systemWide: () -> Element?,
                                 belongsToTarget: (Element) -> Bool) -> Element? {
        if let field = application(), belongsToTarget(field) { return field }
        if let field = systemWide(), belongsToTarget(field) { return field }
        return nil
    }

    static func search<Node>(root: Node, limit: Int = 512,
                             matches: (Node) -> Bool, children: (Node) -> [Node],
                             same: (Node, Node) -> Bool, shouldStop: () -> Bool = { false }) -> Node? {
        var pending = [root]
        var visited: [Node] = []
        while !pending.isEmpty, visited.count < limit, !shouldStop() {
            let node = pending.removeLast()
            guard !visited.contains(where: { same($0, node) }) else { continue }
            visited.append(node)
            if matches(node) { return node }
            pending.append(contentsOf: children(node).prefix(limit).reversed())
        }
        return nil
    }
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

    @MainActor
    static func captureTarget() -> DictationInsertionTarget? {
        guard let application = keyboardApplication() else { return nil }
        return DictationInsertionTarget(processIdentifier: application.processIdentifier,
                                        startedInSecureInput: IsSecureEventInputEnabled())
    }

    /// Electron editors expose their focused field only after assistive
    /// technology requests the accessibility tree. Warm it while recording,
    /// rather than waiting until the transcript is ready to insert.
    @MainActor
    static func prepareForDictation() {
        guard AXIsProcessTrusted(),
              let application = keyboardApplication() else { return }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        // https://www.electronjs.org/docs/latest/tutorial/accessibility#macos
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Reads frontmost app + AX focused element metadata. Returns nil when
    /// nothing resolvable (no Accessibility permission, no focused element).
    @MainActor
    static func focusedFieldMetadata() -> FocusedFieldInfo? {
        resolveFocusedElement()?.info
    }

    /// The focused element when it is safe to read back, for watching what
    /// the user does to inserted text. Nil for secure fields.
    @MainActor
    static func focusedElementForObservation() -> AXUIElement? {
        guard let focus = resolveFocusedElement(),
              !DictationFieldSecurity.isLikelySecure(role: focus.info.role, subrole: focus.info.subrole)
        else { return nil }
        return focus.element
    }

    /// Inserts text using the priority ladder documented at the top of this
    /// file. Never throws.
    @MainActor
    static func insert(_ text: String, target: DictationInsertionTarget? = nil) async -> InsertionOutcome {
        // Empty text would degenerate into "wipe the selection" (priority 1)
        // or "paste nothing while clobbering the clipboard" (priority 2), so it
        // is rejected before anything else happens.
        guard !text.isEmpty else { return .failed("empty text") }
        guard !IsSecureEventInputEnabled(), target?.startedInSecureInput != true else {
            return .blockedSecureField
        }
        if let target, keyboardApplication()?.processIdentifier != target.processIdentifier {
            return .failed("focused app changed since dictation started")
        }

        prepareForDictation()
        let targetPID = keyboardApplication()?.processIdentifier
        var resolvedFocus = resolveFocusedElement()
        for _ in 0..<4 where resolvedFocus == nil {
            // Electron may publish its tree asynchronously. Do not move a
            // transcript into another app if focus changes during this wait.
            do { try await Task.sleep(for: .milliseconds(75)) }
            catch { return .failed("dictation cancelled") }
            guard keyboardApplication()?.processIdentifier == targetPID else {
                return .failed("focused app changed")
            }
            resolvedFocus = resolveFocusedElement()
        }
        guard let focus = resolvedFocus else {
            // AX focus is optional for ordinary keyboard paste. This path is
            // available only to a real shortcut session whose app stayed put.
            HeyMateLog.log("DictationInserter: AX focus unavailable; using shortcut target's keyboard paste")
            return await insertUsingShortcutTarget(text, target: target)
        }
        guard !IsSecureEventInputEnabled() else { return .blockedSecureField }
        if let target, keyboardApplication()?.processIdentifier != target.processIdentifier {
            return .failed("focused app changed since dictation started")
        }

        // Security gate — ALWAYS before any mutation.
        if DictationFieldSecurity.isLikelySecure(role: focus.info.role, subrole: focus.info.subrole) {
            HeyMateLog.log("⚠️ DictationInserter: blocked insertion into likely-secure field in \(focus.info.appName ?? "unknown app")")
            return .blockedSecureField
        }

        // Normal paste goes through the editor's input handling. AX writes
        // can return success without updating the app's actual draft state.
        if await insertViaPasteboard(text, processIdentifier: target?.processIdentifier ?? keyboardApplication()?.processIdentifier) {
            return .insertedViaPasteboard
        }
        if setSelectedText(on: focus.element, to: text) == .success {
            return .insertedViaAccessibility
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

    /// Keyboard delivery does not require the recipient to expose an AX tree.
    /// Kept separate so the signed app can exercise this exact fallback in QA.
    @MainActor
    static func insertUsingShortcutTarget(_ text: String, target: DictationInsertionTarget?) async -> InsertionOutcome {
        guard !text.isEmpty else { return .failed("empty text") }
        guard DictationPastePolicy.allowsUnexposedField(
            target: target, currentPID: keyboardApplication()?.processIdentifier,
            secureInput: IsSecureEventInputEnabled(), canPostEvents: CGPreflightPostEventAccess()
        ) else {
            return .failed("no focused field or safe shortcut paste target")
        }
        // If AX does expose a secure field, it remains blocked even if its
        // app did not enable macOS Secure Event Input.
        if let focus = resolveFocusedElement(),
           DictationFieldSecurity.isLikelySecure(role: focus.info.role, subrole: focus.info.subrole) {
            return .blockedSecureField
        }
        guard keyboardApplication()?.processIdentifier == target?.processIdentifier,
              !IsSecureEventInputEnabled() else { return .failed("paste target changed") }
        return await insertViaPasteboard(text, processIdentifier: target?.processIdentifier) ? .insertedViaPasteboard
            : .unsupportedPath("couldn't post dictation paste")
    }

    // MARK: - Focus resolution

    private struct ResolvedFocus {
        let element: AXUIElement
        let info: FocusedFieldInfo
    }

    @MainActor
    private static func resolveFocusedElement() -> ResolvedFocus? {
        guard let frontmostApplication = keyboardApplication() else { return nil }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        // App-scoped focus can succeed when the system-wide AX proxy has no
        // focused element. Never use a field belonging to a different app.
        let directFocus = DictationFocusLookup.resolve(
            application: { focusedElement(in: applicationElement) },
            systemWide: { focusedElement(in: AXUIElementCreateSystemWide()) },
            belongsToTarget: { element in
                belongsToApplication(element, root: applicationElement,
                                     pid: frontmostApplication.processIdentifier)
            }
        )
        // Some embedded web views do not implement AXFocusedUIElement on
        // their host app, but do expose AXFocused on the actual text field.
        // Search only that app's focused window, never an arbitrary editor.
        let focusedElement = directFocus.flatMap { isTextEntry($0) ? $0 : nil }
            ?? focusedTextEntry(in: applicationElement)
        guard let focusedElement else { return nil }

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

    @MainActor
    private static func keyboardApplication() -> NSRunningApplication? {
        // Nonactivating panels can own keyboard focus while another app
        // remains NSWorkspace's frontmost app (and owns the menu bar).
        if let application = elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(application, &pid) == .success,
               let running = NSRunningApplication(processIdentifier: pid),
               !running.isTerminated, running.bundleIdentifier != nil,
               running.activationPolicy != .prohibited { return running }
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated, frontmost.bundleIdentifier != nil,
              frontmost.activationPolicy != .prohibited else { return nil }
        return frontmost
    }

    @MainActor
    private static func belongsToApplication(_ element: AXUIElement, root: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        if AXUIElementGetPid(element, &owner) == .success, owner == pid { return true }
        // WebKit accessibility objects can live in a WebContent process.
        // Their parent chain, rather than the renderer PID, proves ownership.
        var current = element
        for _ in 0..<64 {
            if CFEqual(current, root) { return true }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return false }
            current = parent
        }
        return false
    }

    @MainActor
    private static func isTextEntry(_ element: AXUIElement) -> Bool {
        guard let role = stringValue(of: element, attribute: kAXRoleAttribute) else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
            || DictationFieldSecurity.isLikelySecure(role: role, subrole: nil)
    }

    @MainActor
    private static func focusedTextEntry(in application: AXUIElement) -> AXUIElement? {
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(0.25)
        let result = DictationFocusLookup.search(root: window, matches: { element in
            guard isTextEntry(element) else { return false }
            var focused: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused) == .success
                && (focused as? Bool) == true
        }, children: { element in
            if let focus = focusedElement(in: element), !CFEqual(focus, element) { return [focus] }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success
            else { return [] }
            return children as? [AXUIElement] ?? []
        }, same: { CFEqual($0, $1) }, shouldStop: { Date() >= deadline })
        if result != nil { HeyMateLog.log("DictationInserter: resolved focused text field through window tree") }
        return result
    }

    @MainActor
    private static func elementAttribute(_ root: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    @MainActor
    private static func focusedElement(in root: AXUIElement) -> AXUIElement? {
        elementAttribute(root, kAXFocusedUIElementAttribute)
    }

    /// AX reads are thread-safe pure queries, so this helper deliberately stays
    /// usable from any isolation domain.
    private nonisolated static func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var boxedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &boxedValue)
        guard result == .success, let value = boxedValue as? String else { return nil }
        return value
    }

    // MARK: - Accessibility selected-text fallback

    /// Replaces the current selection via the Accessibility API. Returns the
    /// raw AXError so the caller can decide whether the failure is benign
    /// ("this field does not expose selectable text" → fall down the ladder).
    @MainActor
    private static func setSelectedText(on element: AXUIElement, to text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }

    // MARK: - Pasteboard + synthetic Cmd+V

    /// Puts `text` on the pasteboard, synthesizes Cmd+V toward the frontmost
    /// app, waits for the paste to be consumed, then restores the user's
    /// original clipboard contents. Returns false only when the synthetic
    /// events could not even be created.
    @MainActor
    private static func insertViaPasteboard(_ text: String, processIdentifier: pid_t?) async -> Bool {
        guard let processIdentifier else { return false }
        let snapshotOfOriginalClipboard = ClipboardSnapshot.save()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            ClipboardSnapshot.restore(snapshotOfOriginalClipboard, ifUnchangedSince: pasteboard.changeCount)
            return false
        }
        let insertionChangeCount = pasteboard.changeCount

        // Virtual key code 9 is the letter "V"; paired with the command flag
        // this produces a faithful Cmd+V press. A private source keeps the
        // synthetic chord independent of the held dictation modifiers.
        let source = CGEventSource(stateID: .privateState)
        guard let commandVKeyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCodeForLetterV, keyDown: true),
              let commandVKeyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyCodeForLetterV, keyDown: false)
        else {
            HeyMateLog.log("⚠️ DictationInserter: could not synthesize Cmd+V events for pasteboard insertion")
            ClipboardSnapshot.restore(snapshotOfOriginalClipboard, ifUnchangedSince: insertionChangeCount)
            return false
        }

        commandVKeyDown.flags = .maskCommand
        commandVKeyUp.flags = .maskCommand
        // Address the recipient explicitly. Posting to the global HID tap can
        // be diverted by an overlay or another app while recognition finishes.
        commandVKeyDown.postToPid(processIdentifier)
        commandVKeyUp.postToPid(processIdentifier)
        let recipient = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? "unknown"
        HeyMateLog.log("DictationInserter: keyboard paste posted to \(recipient) (\(processIdentifier))")

        // Wait for the target app to consume the paste BEFORE restoring the
        // clipboard — restoring too early races the app's pasteboard read and
        // can end up pasting the user's previous clipboard content instead.
        // Task.sleep suspends rather than blocks, keeping the main actor free.
        // `try?` is deliberate: even a cancelled task must still reach the
        // clipboard restore below.
        _ = try? await Task.sleep(nanoseconds: pasteConsumptionDelayNanoseconds)

        ClipboardSnapshot.restore(snapshotOfOriginalClipboard, ifUnchangedSince: insertionChangeCount)
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
                HeyMateLog.log("⚠️ DictationInserter: could not synthesize keystroke events for typed insertion")
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
enum ClipboardSnapshot {

    struct Content {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    /// Materialize every representation before clearing the pasteboard.
    @MainActor
    static func save(from pasteboard: NSPasteboard = .general) -> Content {
        return Content(
            items: (pasteboard.pasteboardItems ?? []).map { item in
                var representations: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { representations[type] = data }
                }
                return representations
            }
        )
    }

    /// Restore all original formats unless another copy replaced our text.
    @MainActor
    static func restore(_ content: Content, ifUnchangedSince changeCount: Int,
                        to pasteboard: NSPasteboard = .general) {
        // A copy made while the target consumes the paste belongs to the user.
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let items = content.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
