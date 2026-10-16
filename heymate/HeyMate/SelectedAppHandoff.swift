import AppKit
import Combine
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// Explicit one-shot delivery to a chosen running app. No app monitoring,
/// network submission, or automatic Return key. An explicit second action
/// can request Return after the user reviews the pasted content.
@MainActor
final class SelectedAppHandoff: ObservableObject {
    struct Target: Identifiable {
        let app: NSRunningApplication
        let pid: pid_t
        let bundleID: String
        let launchedAt: Date?
        var id: pid_t { pid }
        var name: String { app.localizedName ?? bundleID }
        var isCurrent: Bool {
            guard let launchedAt, let live = NSRunningApplication(processIdentifier: pid) else { return false }
            return !live.isTerminated && live.bundleIdentifier == bundleID && live.launchDate == launchedAt
        }
    }
    enum Phase: Equatable { case editing, capturing, delivering, delivered, submissionRequested, failed(String) }
    @Published var targetID: pid_t = 0
    @Published var comment = ""
    @Published var images: [ChatImageAttachment] = []
    @Published private(set) var targets: [Target] = []
    @Published private(set) var phase: Phase = .editing
    private var clipboard: ClipboardLease?
    private var deliveryTask: Task<Void, Never>?

    var target: Target? { targets.first { $0.id == targetID } }
    var busy: Bool { phase == .capturing || phase == .delivering }

    func refreshTargets() {
        targets = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
                  let bundle = app.bundleIdentifier, app.launchDate != nil else { return nil }
            return Target(app: app, pid: app.processIdentifier, bundleID: bundle, launchedAt: app.launchDate)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let loaded = try panel.urls.prefix(max(0, ChatImageAttachment.maximumCount - images.count)).map(ChatImageAttachment.load)
            images += loaded
            phase = .editing
        } catch { phase = .failed("Could not read an image. Existing selection is still here.") }
    }

    func captureRegion() {
        guard !busy, images.count < ChatImageAttachment.maximumCount else { return }
        guard CGPreflightScreenCaptureAccess() else {
            phase = .failed("Screen Recording permission needed. Enable HeyMate in System Settings, then retry.")
            return
        }
        phase = .capturing
        Task { [weak self] in
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-region-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: path) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", path.path]
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                guard let self else { return }
                if FileManager.default.fileExists(atPath: path.path) {
                    self.images.append(try ChatImageAttachment.load(from: path))
                }
                self.phase = .editing // Escape means no image, not a failed send.
            } catch { self?.phase = .failed("Region capture failed. Retry or choose an image file.") }
        }
    }

    func deliver() {
        guard !busy, let target, target.isCurrent, !images.isEmpty else {
            phase = .failed("Choose a running app and at least one image.")
            return
        }
        guard AXIsProcessTrusted() else {
            phase = .failed("Accessibility permission needed to paste into that app. Enable HeyMate in System Settings, then retry.")
            return
        }
        phase = .delivering
        // Snapshot all representations. Failure to materialize any type aborts
        // instead of silently losing a clipboard manager's promised payload.
        guard let lease = ClipboardLease() else {
            phase = .failed("Clipboard could not be preserved. Copy its content elsewhere, then retry.")
            return
        }
        clipboard = lease
        let payload = images
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { lease.restoreIfOwned(); self.clipboard = nil; self.deliveryTask = nil }
            guard target.isCurrent, target.app.activate(options: [.activateIgnoringOtherApps]) else {
                self.phase = .failed("Chosen app closed. Choose it again.")
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard self.canPaste(to: target) else { throw DeliveryError.targetChanged }
                if !note.isEmpty {
                    guard lease.writeText(note) else { throw DeliveryError.clipboardChanged }
                    try self.paste(to: target)
                    try await Task.sleep(for: .milliseconds(700))
                }
                for image in payload {
                    guard self.canPaste(to: target) else { throw DeliveryError.targetChanged }
                    guard lease.writeImage(image.data) else { throw DeliveryError.clipboardChanged }
                    try self.paste(to: target)
                    try await Task.sleep(for: .milliseconds(900))
                }
                self.phase = .delivered
            } catch {
                self.phase = .failed("Handoff stopped. Some content may already be pasted; review chosen app before retrying.")
            }
        }
    }

    /// Separate action after review in the destination app. A posted key is
    /// not a remote acknowledgement and is never retried automatically.
    func requestSubmission() {
        guard phase == .delivered, let target, target.isCurrent, AXIsProcessTrusted() else {
            phase = .failed("Chosen app or Accessibility access changed. Review pasted content before retrying.")
            return
        }
        phase = .delivering
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil }
            guard target.app.activate(options: [.activateIgnoringOtherApps]) else {
                self.phase = .failed("Could not activate chosen app. Submit there manually.")
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard self.canPaste(to: target),
                      let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { throw DeliveryError.targetChanged }
                down.flags = []
                up.flags = []
                down.postToPid(target.pid)
                up.postToPid(target.pid)
                self.phase = .submissionRequested
            } catch { self.phase = .failed("Submission not confirmed. Check chosen app; do not resend without checking.") }
        }
    }

    private enum DeliveryError: Error { case targetChanged, clipboardChanged, eventUnavailable }
    private func canPaste(to target: Target) -> Bool {
        target.isCurrent && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }
    private func paste(to target: Target) throws {
        guard canPaste(to: target), let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { throw DeliveryError.eventUnavailable }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.pid)
        up.postToPid(target.pid)
    }
}

/// Ownership fence protects clipboard changes made during delivery.
@MainActor
private final class ClipboardLease {
    private let pasteboard = NSPasteboard.general
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private var ownedCount: Int
    init?() {
        let board = NSPasteboard.general
        let count = board.changeCount
        var values: [[NSPasteboard.PasteboardType: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations[type] = data
            }
            values.append(representations)
        }
        guard board.changeCount == count else { return nil }
        saved = values
        ownedCount = count
    }
    func writeText(_ text: String) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return write(item)
    }
    func writeImage(_ data: Data) -> Bool {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        return write(item)
    }
    private func write(_ item: NSPasteboardItem) -> Bool {
        guard pasteboard.changeCount == ownedCount else { return false }
        pasteboard.clearContents()
        let result = pasteboard.writeObjects([item])
        ownedCount = pasteboard.changeCount
        return result
    }
    func restoreIfOwned() {
        guard pasteboard.changeCount == ownedCount else { return }
        pasteboard.clearContents()
        let items = saved.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

struct SelectedAppHandoffView: View {
    @StateObject private var handoff = SelectedAppHandoff()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hand off selected context").font(.title2)
            Text("Choose an app, select images, add a comment, then review. HeyMate pastes into that app. Review there before submitting.").font(.caption).foregroundStyle(.secondary)
            Picker("Target app", selection: $handoff.targetID) {
                Text("Choose app").tag(pid_t(0))
                ForEach(handoff.targets) { app in Text("\(app.name) · \(app.bundleID)").tag(app.id) }
            }.disabled(handoff.busy)
            HStack {
                Button("Select screen region…") { handoff.captureRegion() }
                Button("Choose images…") { handoff.chooseImages() }
                Button("Refresh apps") { handoff.refreshTargets() }
            }.disabled(handoff.busy || handoff.phase == .delivered)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(handoff.images) { image in
                        VStack {
                            if let thumbnail = image.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 120, height: 90) }
                            Button("Remove") { handoff.images.removeAll { $0.id == image.id } }.font(.caption).disabled(handoff.busy)
                        }
                    }
                }
            }.frame(height: 120)
            TextEditor(text: $handoff.comment).frame(height: 100).disabled(handoff.busy)
            Text("Review target, images and comment. Switching apps or changing clipboard stops delivery.").font(.caption).foregroundStyle(.secondary)
            if case .failed(let error) = handoff.phase {
                Text(error).foregroundStyle(.orange)
                Button("Open Privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
                }
            }
            if handoff.phase == .delivered {
                Text("Paste requested. Review content in chosen app. Use Send with Return only when Return submits there, or submit there manually.").font(.caption).foregroundStyle(.green)
                Button("Send with Return in \(handoff.target?.name ?? "app")") { handoff.requestSubmission() }
            }
            if handoff.phase == .submissionRequested {
                Text("Submission key requested. Confirm result in chosen app; HeyMate cannot confirm delivery.").font(.caption).foregroundStyle(.green)
            }
            HStack {
                Button(handoff.phase == .delivered || handoff.phase == .submissionRequested ? "Detach / done" : "Close") { dismiss() }.disabled(handoff.busy)
                Spacer()
                if handoff.busy { ProgressView().controlSize(.small) }
                Button("Paste into \(handoff.target?.name ?? "app")") { handoff.deliver() }
                    .disabled(handoff.busy || handoff.images.isEmpty || handoff.target == nil || handoff.phase == .delivered || handoff.phase == .submissionRequested)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620).onAppear { handoff.refreshTargets() }
        .interactiveDismissDisabled(handoff.busy)
    }
}
