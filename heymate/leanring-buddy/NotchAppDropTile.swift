//
//  NotchAppDropTile.swift
//  leanring-buddy
//
//  AppKit file-URL drag of HeyMate.app for Privacy settings. The whole
//  card is the drag source. SwiftUI
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

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dragCard
                .help("Drag HeyMate.app into the Settings list")
                .onAppear(perform: WindowPositionManager.prewarmAppBundleForPrivacyDrop)

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

    /// The whole card is the drag source, not just the icon: the AppKit view
    /// sits on top and covers every point of it.
    private var dragCard: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: WindowPositionManager.runningAppBundleURL.path))
                .resizable()
                .frame(width: 44, height: 44)
                .scaleEffect(isHovering && !isDragging ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("HeyMate.app")
                    .font(DS.Fonts.bodyLarge.weight(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(isDragging
                     ? "Drop it in the list, then turn it on."
                     : "Grab anywhere here and drag into Settings.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovering ? DS.Colors.textSecondary : DS.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? DS.Colors.surface3 : DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHovering ? DS.Colors.borderStrong : DS.Colors.borderSubtle,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            AppBundleDragHandle(
                settingsPane: missingAccessibility ? .accessibility : .screenRecording,
                onHoverChange: { isHovering = $0 },
                onDragChange: { isDragging = $0 }
            )
        )
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    private func settingsLink(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
    }
}

enum PrivacySettingsPane {
    case accessibility
    case screenRecording

    @MainActor
    func open() {
        switch self {
        case .accessibility: WindowPositionManager.openAccessibilitySettings()
        case .screenRecording: WindowPositionManager.openScreenRecordingSettings()
        }
    }
}

private struct AppBundleDragHandle: NSViewRepresentable {
    var settingsPane: PrivacySettingsPane
    var onHoverChange: (Bool) -> Void
    var onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppBundleDragSourceView {
        let view = AppBundleDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {
        nsView.settingsPane = settingsPane
        nsView.onHoverChange = onHoverChange
        nsView.onDragChange = onDragChange
    }
}

/// Transparent drag source laid over the whole card. Writes the real file
/// URL so System Settings treats the drop as an application bundle, not a
/// promised copy.
final class AppBundleDragSourceView: NSView, NSDraggingSource {
    var settingsPane: PrivacySettingsPane = .accessibility
    var onHoverChange: ((Bool) -> Void)?
    var onDragChange: ((Bool) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var trackingArea: NSTrackingArea?

    /// The notch panel is rarely key. Without this the first click only
    /// focuses the panel and `mouseDown` never arrives, which is why the drag
    /// worked on some tries and not others.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent else { return }
        let delta = hypot(
            event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
            event.locationInWindow.y - mouseDownEvent.locationInWindow.y
        )
        guard delta >= 3 else { return }
        self.mouseDownEvent = nil
        beginAppBundleDrag(downEvent: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        NSCursor.openHand.set()
    }

    private func beginAppBundleDrag(downEvent: NSEvent) {
        let bundleURL = WindowPositionManager.prepareAppBundleForPrivacyDrop()
        let draggingItem = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(fileURL: bundleURL))
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 56, height: 56)

        // Centre the icon under the point the user grabbed, so it follows the
        // cursor wherever on the card the drag started.
        let grabPoint = convert(downEvent.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: grabPoint.x - 28, y: grabPoint.y - 28, width: 56, height: 56),
            contents: icon
        )

        onDragChange?(true)
        NotificationCenter.default.post(name: .clickyPrivacyDragDidBegin, object: nil)

        // Start from the mouse-down event: the drag image then begins where
        // the press happened instead of jumping a few points behind.
        let session = beginDraggingSession(with: [draggingItem], event: downEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        settingsPane.open()
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
        onDragChange?(false)
        onHoverChange?(false)
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
