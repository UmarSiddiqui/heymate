//
//  NotchAppDropTile.swift
//  leanring-buddy
//
//  AppKit file-URL drag of HeyMate.app for Privacy settings. SwiftUI
//  `.draggable(FileRepresentation)` sends a file *promise*, which the
//  Accessibility / Screen Recording lists reject. The notch card also
//  sits above Settings and eats the drop — we click-through + fade it
//  for the duration of the drag.
//

import AppKit
import SwiftUI

struct NotchAppDropTile: View {
    var missingAccessibility: Bool
    var missingScreenRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppBundleDragHandle()
                .frame(height: 64)
                .help("Drag HeyMate.app into the Settings list")

            HStack(spacing: 6) {
                if missingAccessibility {
                    settingsLink(
                        title: "Open Accessibility",
                        action: {
                            WindowPositionManager.revealPreparedAppInFinder()
                            WindowPositionManager.openAccessibilitySettings()
                        }
                    )
                }
                if missingScreenRecording {
                    settingsLink(
                        title: "Open Screen Recording",
                        action: {
                            WindowPositionManager.revealPreparedAppInFinder()
                            WindowPositionManager.openScreenRecordingSettings()
                        }
                    )
                }
                settingsLink(
                    title: "Show in Finder",
                    action: WindowPositionManager.revealPreparedAppInFinder
                )
            }
        }
    }

    private func settingsLink(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().stroke(DS.Colors.borderStrong, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct AppBundleDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragSourceView {
        AppBundleDragSourceView()
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {}
}

/// Writes the real file URL + legacy filenames type so System Settings
/// treats the drop as an application bundle, not a promised copy.
final class AppBundleDragSourceView: NSView, NSDraggingSource {
    private var dragStartLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let icon = NSWorkspace.shared.icon(forFile: WindowPositionManager.runningAppBundleURL.path)
        let iconRect = NSRect(x: 10, y: (bounds.height - 44) / 2, width: 44, height: 44)
        icon.draw(in: iconRect)

        let title = NSAttributedString(
            string: "HeyMate.app",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
        )
        let subtitle = NSAttributedString(
            string: "Drag into the Settings list, then turn it on.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5)
            ]
        )
        title.draw(at: NSPoint(x: 64, y: bounds.midY + 2))
        subtitle.draw(at: NSPoint(x: 64, y: bounds.midY - 14))
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartLocation else { return }
        let delta = hypot(
            event.locationInWindow.x - dragStartLocation.x,
            event.locationInWindow.y - dragStartLocation.y
        )
        guard delta >= 4 else { return }
        self.dragStartLocation = nil
        beginAppBundleDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
    }

    private func beginAppBundleDrag(with event: NSEvent) {
        let bundleURL = WindowPositionManager.prepareAppBundleForPrivacyDrop()
        let pasteboardItem = AppBundlePasteboardWriter(fileURL: bundleURL)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 64, height: 64)
        draggingItem.setDraggingFrame(
            NSRect(x: 10, y: (bounds.height - 44) / 2, width: 44, height: 44),
            contents: icon
        )

        NotificationCenter.default.post(name: .clickyPrivacyDragDidBegin, object: nil)
        WindowPositionManager.openAccessibilitySettings()

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        NotificationCenter.default.post(name: .clickyPrivacyDragDidEnd, object: nil)
    }
}

final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `.fileURL` only, and only once.
    ///
    /// The list used to also carry `NSFilenamesPboardType` and a literal
    /// `"public.file-url"`. The literal is exactly what `.fileURL` already is,
    /// so it was a duplicate; `NSFilenamesPboardType` is a legacy *reading*
    /// constant and is not a UTI, so declaring it as writable made AppKit
    /// reject the whole declaration at runtime:
    ///
    ///     'NSFilenamesPboardType' is not a valid UTI string. Cannot use an
    ///     invalid UTI as a type returned from -writeableTypesForPasteboard:
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .fileURL else { return nil }
        return fileURL.absoluteString
    }
}
