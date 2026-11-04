import AppKit
import Foundation

// Keep the probe independent of the app's logging/profile setup.
enum HeyMateLog {
    nonisolated static func log(_ message: String) {}
}

@main struct DictationInsertionProbe {
    @MainActor static func main() {
        let target = DictationInsertionTarget(processIdentifier: 123, startedInSecureInput: false)
        precondition(DictationPastePolicy.allowsUnexposedField(target: target, currentPID: 123,
            secureInput: false, canPostEvents: true))
        precondition(!DictationPastePolicy.allowsUnexposedField(target: target, currentPID: 456,
            secureInput: false, canPostEvents: true))
        precondition(!DictationPastePolicy.allowsUnexposedField(target: target, currentPID: 123,
            secureInput: true, canPostEvents: true))
        precondition(!DictationPastePolicy.allowsUnexposedField(target: target, currentPID: 123,
            secureInput: false, canPostEvents: false))
        precondition(!DictationPastePolicy.allowsUnexposedField(target: nil, currentPID: 123,
            secureInput: false, canPostEvents: true))
        let secureTarget = DictationInsertionTarget(processIdentifier: 123, startedInSecureInput: true)
        precondition(!DictationPastePolicy.allowsUnexposedField(target: secureTarget, currentPID: 123,
            secureInput: false, canPostEvents: true))
        print("PASS: shortcut paste works without AX focus; app changes, secure input and missing event access block it")
        var queriedSystem = false
        let appFocus = DictationFocusLookup.resolve(
            application: { "target field" },
            systemWide: { queriedSystem = true; return nil },
            belongsToTarget: { $0 == "target field" }
        )
        precondition(appFocus == "target field" && !queriedSystem)
        let fallbackFocus = DictationFocusLookup.resolve(
            application: { nil }, systemWide: { "target field" },
            belongsToTarget: { $0 == "target field" }
        )
        precondition(fallbackFocus == "target field")
        let foreignFocus = DictationFocusLookup.resolve(
            application: { "other process" }, systemWide: { "another process" },
            belongsToTarget: { $0 == "target field" }
        )
        precondition(foreignFocus == nil)
        print("PASS: app-scoped dictation focus works without system-wide focus; fallback and process isolation hold")
        // Host app has no direct focus; a remote web view exposes it on a
        // descendant. The unfocused text field must never win this search.
        let tree = [0: [1, 2], 1: [3], 2: [4], 3: [1], 4: [5]]
        let descendant = DictationFocusLookup.search(root: 0, matches: { $0 == 5 },
            children: { tree[$0] ?? [] }, same: ==)
        precondition(descendant == 5)
        let bounded = DictationFocusLookup.search(root: 0, limit: 3, matches: { $0 == 5 },
            children: { tree[$0] ?? [] }, same: ==)
        precondition(bounded == nil)
        let stopped = DictationFocusLookup.search(root: 0, matches: { $0 == 5 },
            children: { tree[$0] ?? [] }, same: ==, shouldStop: { true })
        precondition(stopped == nil)
        print("PASS: focused descendant lookup crosses embedded tree, skips cycles, and respects bounds")
        // A private pasteboard leaves the user's real clipboard untouched.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        let richData = Data("{\\rtf1 original}".utf8)
        first.setData(richData, forType: .rtf)
        let second = NSPasteboardItem()
        let imageData = Data([0, 1, 2, 3])
        second.setData(imageData, forType: .png)
        precondition(board.writeObjects([first, second]))
        let original = ClipboardSnapshot.save(from: board)

        board.clearContents()
        board.setString("dictation", forType: .string)
        ClipboardSnapshot.restore(original, ifUnchangedSince: board.changeCount, to: board)
        precondition(board.pasteboardItems?.count == 2)
        precondition(board.pasteboardItems?[0].string(forType: .string) == "original")
        precondition(board.pasteboardItems?[0].data(forType: .rtf) == richData)
        precondition(board.pasteboardItems?[1].data(forType: .png) == imageData)

        board.clearContents()
        board.setString("dictation", forType: .string)
        let insertionChangeCount = board.changeCount
        board.clearContents()
        board.setString("new user copy", forType: .string)
        ClipboardSnapshot.restore(original, ifUnchangedSince: insertionChangeCount, to: board)
        precondition(board.string(forType: .string) == "new user copy")

        board.clearContents()
        let empty = ClipboardSnapshot.save(from: board)
        board.setString("dictation", forType: .string)
        ClipboardSnapshot.restore(empty, ifUnchangedSince: board.changeCount, to: board)
        precondition(board.pasteboardItems?.isEmpty != false)
        print("PASS: dictation clipboard preserves all formats, multiple items, newer copies and empty state")
    }
}
