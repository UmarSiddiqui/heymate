//
//  NotchShelfStore.swift
//  leanring-buddy
//
//  The file shelf: drag anything onto the notch and it parks there until
//  you drag it back out, open it, or it ages out. This is the single most
//  useful non-AI thing a notch can do — it turns the dead pixels around
//  the camera into a cross-app clipboard for files.
//
//  Storage rule: we never copy the user's file. The shelf holds security-
//  scoped bookmarks plus a cached QuickLook thumbnail, so a shelved item
//  survives relaunch without HeyMate quietly duplicating gigabytes into
//  Application Support. Items whose original file has moved are dropped on
//  the next load rather than showing a dead row.
//

import AppKit
import Combine
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class NotchShelfStore: ObservableObject {

    struct ShelfItem: Identifiable, Equatable {
        let id: UUID
        let fileURL: URL
        let displayName: String
        let addedAt: Date
        var thumbnail: NSImage?

        static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
            lhs.id == rhs.id && lhs.fileURL == rhs.fileURL
        }
    }

    @Published private(set) var items: [ShelfItem] = []

    /// Shelved files disappear after this long so the shelf stays a
    /// staging area, not a second Downloads folder. Matches NotchDrop's
    /// default and is the behavior users already expect.
    static let itemLifetime: TimeInterval = 60 * 60 * 24

    /// Cap so a runaway drag (a folder of 4,000 photos) cannot blow up the
    /// UI or the bookmark file.
    static let maximumItemCount = 24

    private let bookmarkFileURL: URL

    init(bookmarkFileURL: URL? = nil) {
        self.bookmarkFileURL = bookmarkFileURL ?? Self.defaultBookmarkFileURL()
        loadPersistedItems()
    }

    private static func defaultBookmarkFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        return applicationSupport.appendingPathComponent("notch-shelf.json")
    }

    // MARK: Mutation

    /// Returns the number of URLs actually accepted, so the drop target can
    /// tell the user "3 files" versus silently swallowing duplicates.
    @discardableResult
    func accept(fileURLs: [URL]) -> Int {
        var acceptedCount = 0
        for fileURL in fileURLs {
            guard !items.contains(where: { $0.fileURL == fileURL }) else { continue }
            let item = ShelfItem(
                id: UUID(),
                fileURL: fileURL,
                displayName: fileURL.lastPathComponent,
                addedAt: Date(),
                thumbnail: nil
            )
            items.insert(item, at: 0)
            acceptedCount += 1
            loadThumbnail(for: item)
        }
        if items.count > Self.maximumItemCount {
            items = Array(items.prefix(Self.maximumItemCount))
        }
        persist()
        return acceptedCount
    }

    func remove(itemID: UUID) {
        items.removeAll { $0.id == itemID }
        persist()
    }

    func removeAll() {
        items.removeAll()
        persist()
    }

    func reveal(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    func open(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        NSWorkspace.shared.open(item.fileURL)
    }

    /// Drop anything older than `itemLifetime`. Called when the notch card
    /// opens rather than on a timer — nobody needs the shelf pruned while
    /// they are not looking at it.
    func pruneExpiredItems(asOf referenceDate: Date = Date()) {
        let survivingItems = items.filter {
            referenceDate.timeIntervalSince($0.addedAt) < Self.itemLifetime
        }
        guard survivingItems.count != items.count else { return }
        items = survivingItems
        persist()
    }

    // MARK: Activity

    var activity: NotchActivity? {
        guard !items.isEmpty else { return nil }
        return NotchActivity(
            kind: .shelf,
            trailingText: items.count == 1 ? "1 file" : "\(items.count) files"
        )
    }

    // MARK: Thumbnails

    private func loadThumbnail(for item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.fileURL,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }
            let image = NSImage(cgImage: representation.cgImage, size: .zero)
            Task { @MainActor in
                guard let self,
                      let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[index].thumbnail = image
            }
        }
    }

    // MARK: Persistence

    private struct PersistedShelfItem: Codable {
        let id: UUID
        let bookmarkData: Data
        let displayName: String
        let addedAt: Date
    }

    private func persist() {
        let persisted: [PersistedShelfItem] = items.compactMap { item in
            guard let bookmarkData = try? item.fileURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return PersistedShelfItem(
                id: item.id,
                bookmarkData: bookmarkData,
                displayName: item.displayName,
                addedAt: item.addedAt
            )
        }
        guard let encoded = try? JSONEncoder().encode(persisted) else { return }
        try? encoded.write(to: bookmarkFileURL, options: .atomic)
    }

    private func loadPersistedItems() {
        guard let data = try? Data(contentsOf: bookmarkFileURL),
              let persisted = try? JSONDecoder().decode([PersistedShelfItem].self, from: data) else { return }

        let cutoffDate = Date().addingTimeInterval(-Self.itemLifetime)
        var restored: [ShelfItem] = []
        for entry in persisted where entry.addedAt > cutoffDate {
            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: entry.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: resolvedURL.path) else { continue }

            restored.append(
                ShelfItem(
                    id: entry.id,
                    fileURL: resolvedURL,
                    displayName: entry.displayName,
                    addedAt: entry.addedAt,
                    thumbnail: nil
                )
            )
        }
        items = restored
        for item in restored {
            loadThumbnail(for: item)
        }
    }

    // MARK: Drag out

    /// Pasteboard writer for dragging an item back off the shelf into any
    /// app that accepts files.
    func pasteboardItem(for itemID: UUID) -> NSPasteboardItem? {
        guard let item = items.first(where: { $0.id == itemID }) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.fileURL.absoluteString, forType: .fileURL)
        return pasteboardItem
    }
}
