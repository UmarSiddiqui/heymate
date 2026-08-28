//
//  ClipboardHistoryStore.swift
//  leanring-buddy
//
//  Recent copies, reachable from the notch.
//
//  Two rules make this safe enough to ship in an app that also has screen
//  and microphone access:
//
//  1. Anything a password manager marks with `org.nspasteboard.ConcealedType`
//     is skipped entirely and never enters memory.
//  2. History is memory-only. Nothing is written to disk, so there is no
//     plaintext secret file to leak, and quitting HeyMate erases it.
//
//  NSPasteboard has no change notification, so a poll is unavoidable. We
//  poll `changeCount` — an integer read, not a data read — at 1.5 s, and
//  only while the feature is enabled.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ClipboardHistoryStore: ObservableObject {

    struct ClipboardEntry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let copiedAt: Date

        /// Single-line preview for a list row.
        var preview: String {
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
        }
    }

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isEnabled = false

    static let maximumEntryCount = 40

    /// Pasteboard type password managers set to opt out of history tools.
    /// Respecting it is the whole reason this feature is acceptable.
    nonisolated static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Some tools use this instead to mean "transient, do not record".
    nonisolated static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var pollCancellable: AnyCancellable?
    private var lastObservedChangeCount = NSPasteboard.general.changeCount

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            lastObservedChangeCount = NSPasteboard.general.changeCount
            startPolling()
        } else {
            stopPolling()
            entries.removeAll()
        }
    }

    private func startPolling() {
        stopPolling()
        pollCancellable = Timer.publish(every: 1.5, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.captureIfChanged() }
    }

    private func stopPolling() {
        pollCancellable?.cancel()
        pollCancellable = nil
    }

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = pasteboard.changeCount

        guard Self.shouldRecord(pasteboard: pasteboard) else { return }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Re-copying the same thing should move it to the top, not create
        // a duplicate row.
        entries.removeAll { $0.text == text }
        entries.insert(
            ClipboardEntry(id: UUID(), text: text, copiedAt: Date()),
            at: 0
        )
        if entries.count > Self.maximumEntryCount {
            entries = Array(entries.prefix(Self.maximumEntryCount))
        }
    }

    nonisolated static func shouldRecord(pasteboard: NSPasteboard) -> Bool {
        guard let availableTypes = pasteboard.types else { return false }
        if availableTypes.contains(concealedPasteboardType) { return false }
        if availableTypes.contains(transientPasteboardType) { return false }
        return true
    }

    func copyToPasteboard(entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastObservedChangeCount = pasteboard.changeCount
    }

    func clear() {
        entries.removeAll()
    }
}
