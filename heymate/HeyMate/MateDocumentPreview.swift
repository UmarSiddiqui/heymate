import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Read-only document surface shared by chat outputs and the mate's Files drawer.
struct MateDocumentPreview: View {
    let path: String
    let onClose: () -> Void

    @State private var content: MateDocumentContent?
    @State private var expanded = false

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(DS.Fonts.control.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "File")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                if let text = content?.text {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy document")
                    .accessibilityLabel("Copy document")
                }
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open in default app")
                .accessibilityLabel("Open in default app")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                Button { expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Expand preview")
                    .accessibilityLabel("Expand preview")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Close preview")
                    .accessibilityLabel("Close preview")
            }
            .buttonStyle(.plain)
            .padding(16)
            Divider()
            documentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.surface1)
        .task(id: path) {
            content = nil
            let requestedPath = path
            let loaded = await Task.detached(priority: .userInitiated) {
                MateDocumentContent.load(path: requestedPath)
            }.value
            guard !Task.isCancelled else { return }
            content = loaded
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(url.lastPathComponent).font(DS.Fonts.headline)
                    Spacer()
                    Button("Done") { expanded = false }
                }
                .padding(16)
                Divider()
                documentBody
            }
            .frame(minWidth: 600, idealWidth: 800, minHeight: 560, idealHeight: 720)
        }
    }

    @ViewBuilder private var documentBody: some View {
        switch content {
        case .markdown(let text):
            ScrollView {
                ChatMarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        case .plainText(let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(DS.Fonts.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        case .quickLook:
            MateQuickLookPreview(url: url)
        case .unavailable(let reason):
            VStack(spacing: 12) {
                Image(systemName: "doc.questionmark").font(.largeTitle)
                Text(reason).multilineTextAlignment(.center)
                Button("Open in default app") { NSWorkspace.shared.open(url) }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(24)
        case nil:
            ProgressView()
        }
    }
}

nonisolated enum MateDocumentContent: Sendable, Equatable {
    case markdown(String)
    case plainText(String)
    case quickLook
    case unavailable(String)

    var text: String? {
        switch self {
        case .markdown(let text), .plainText(let text): return text
        default: return nil
        }
    }

    static func load(path: String) -> Self {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .unavailable("This file is no longer available.")
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let markdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        guard markdown || type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true else {
            return .quickLook
        }
        do {
            // Bound memory before decoding; never silently truncate a document.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let maximumBytes = 4 * 1024 * 1024
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                return .unavailable("This document is too large for inline preview. Open it in its default app.")
            }
            guard let text = String(data: data, encoding: .utf8) else { return .quickLook }
            return markdown ? .markdown(text) : .plainText(text)
        } catch {
            return .unavailable("This file could not be read. Check its permissions or open it in its default app.")
        }
    }
}

private struct MateQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL ?? nil) != url {
            view.previewItem = url as NSURL
        }
    }
}
