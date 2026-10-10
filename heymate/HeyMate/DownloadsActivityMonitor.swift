//
//  DownloadsActivityMonitor.swift
//  HeyMate
//
//  Event-driven Downloads folder activity. No polling while idle: a vnode
//  source wakes only when browsers create, rename, or remove download files.
//

import Combine
import Darwin
import Foundation

@MainActor
final class DownloadsActivityMonitor: ObservableObject {
    @Published private(set) var activity: NotchActivity?
    @Published private(set) var activeDownloadCount = 0

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var previousActiveNames: Set<String> = []
    private var completionClearTask: Task<Void, Never>?

    private var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func start() {
        guard directorySource == nil else { return }
        directoryDescriptor = open(downloadsURL.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { [descriptor = directoryDescriptor] in
            close(descriptor)
        }
        directorySource = source
        source.resume()
        refresh()
    }

    func stop() {
        completionClearTask?.cancel()
        completionClearTask = nil
        directorySource?.cancel()
        directorySource = nil
        directoryDescriptor = -1
        previousActiveNames = []
        activeDownloadCount = 0
        activity = nil
    }

    private func refresh() {
        let names = activeDownloadNames()
        let completedSomething = !previousActiveNames.isEmpty && names.isEmpty
        previousActiveNames = names
        activeDownloadCount = names.count
        completionClearTask?.cancel()

        if let firstName = names.sorted().first {
            activity = NotchActivity(
                kind: .download,
                trailingText: names.count == 1 ? Self.pillLabel(for: firstName) : "\(names.count) files"
            )
        } else if completedSomething {
            activity = NotchActivity(
                kind: .download,
                trailingText: "Complete",
                progress: 1,
                tintHex: "34D399",
                expiresAt: Date().addingTimeInterval(4)
            )
            completionClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.activity = nil
            }
        } else {
            activity = nil
        }
    }

    private func activeDownloadNames() -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Set(contents.compactMap(Self.activeDownloadName(for:)))
    }

    nonisolated static func activeDownloadName(for url: URL) -> String? {
        let lowercasedName = url.lastPathComponent.lowercased()
        guard lowercasedName.hasSuffix(".download")
                || lowercasedName.hasSuffix(".crdownload")
                || lowercasedName.hasSuffix(".part") else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    nonisolated static func pillLabel(for fileName: String) -> String {
        let maximumCharacters = 13
        guard fileName.count > maximumCharacters else { return fileName }
        return String(fileName.prefix(maximumCharacters)) + "…"
    }
}
