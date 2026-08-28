//
//  AgentWorkspacePreview.swift
//  leanring-buddy
//
//  Interactive preview for local web artifacts produced by an agent.
//

import AppKit
import SwiftUI
import WebKit

nonisolated enum AgentWorkspacePreviewTarget: Equatable {
    case localServer(URL)
    case file(URL, readAccessURL: URL)

    var url: URL {
        switch self {
        case .localServer(let url), .file(let url, _): return url
        }
    }

    static func resolve(for run: AgentRun, fileManager: FileManager = .default) -> Self? {
        let candidateTexts = run.activity.reversed().map(\.text) + [run.summary, run.latestAction]
        for candidateText in candidateTexts {
            if let localServerURL = firstLocalServerURL(in: candidateText) {
                return .localServer(localServerURL)
            }
        }

        let relativeIndexPaths = ["index.html", "dist/index.html", "public/index.html"]
        for relativeIndexPath in relativeIndexPaths {
            let fileURL = run.workspaceURL.appendingPathComponent(relativeIndexPath)
            if fileManager.fileExists(atPath: fileURL.path) {
                return .file(fileURL, readAccessURL: run.workspaceURL)
            }
        }
        return nil
    }

    private static func firstLocalServerURL(in text: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::[0-9]+)?(?:/[^\s]*)?"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regularExpression.firstMatch(in: text, range: textRange),
              let matchRange = Range(match.range, in: text) else { return nil }

        let normalizedURLString = String(text[matchRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>\"'"))
            .replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        return URL(string: normalizedURLString)
    }
}

struct AgentWorkspacePreview: View {
    let run: AgentRun

    @State private var reloadIdentifier = UUID()

    var body: some View {
        Group {
            if let previewTarget = AgentWorkspacePreviewTarget.resolve(for: run) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari")
                            .foregroundColor(DS.Colors.info)
                        Text(previewTarget.url.absoluteString)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)

                        Button("Reload") { reloadIdentifier = UUID() }
                            .buttonStyle(DSTertiaryButtonStyle())
                        Button("Open in browser") {
                            NSWorkspace.shared.open(previewTarget.url)
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                    }

                    AgentWebPreview(
                        previewTarget: previewTarget,
                        reloadIdentifier: reloadIdentifier
                    )
                    .frame(minHeight: 420)
                    .clipShape(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Preview waiting")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Ask this agent to start its local web app and return a localhost URL. Static index.html files appear automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }
}

/// SwiftUI owns target URL and reload identity. WKWebView remains contained
/// inside this bridge and never becomes another source of app state.
private struct AgentWebPreview: NSViewRepresentable {
    let previewTarget: AgentWorkspacePreviewTarget
    let reloadIdentifier: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        load(previewTarget, in: webView, coordinator: context.coordinator)
        context.coordinator.reloadIdentifier = reloadIdentifier
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let targetChanged = context.coordinator.previewTarget != previewTarget
        let reloadRequested = context.coordinator.reloadIdentifier != reloadIdentifier
        guard targetChanged || reloadRequested else { return }

        load(previewTarget, in: webView, coordinator: context.coordinator)
        context.coordinator.reloadIdentifier = reloadIdentifier
    }

    private func load(
        _ previewTarget: AgentWorkspacePreviewTarget,
        in webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.previewTarget = previewTarget
        switch previewTarget {
        case .localServer(let url):
            webView.load(URLRequest(url: url))
        case .file(let fileURL, let readAccessURL):
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    final class Coordinator {
        var previewTarget: AgentWorkspacePreviewTarget?
        var reloadIdentifier: UUID?
    }
}
