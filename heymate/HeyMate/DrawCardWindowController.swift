//
//  DrawCardWindowController.swift
//  HeyMate
//
//  The note cards a reply can leave on screen with [CARD:title|line|…].
//  Each card is its own small panel at the top right of the screen it
//  explains: it stays after the voice stops, can be dragged anywhere, and
//  closes with its × or Escape. A card naming a photo subject shows the
//  lead image of the best-matching Wikipedia article.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DrawCardWindowController {
    static let maximumCards = 3
    static let cardWidth: CGFloat = 300
    static let photoHeight: CGFloat = 150
    static let gap: CGFloat = 12

    private struct Entry {
        let id: UUID
        let panel: NSPanel
        let model: DrawCardModel
    }

    private var entries: [Entry] = []

    var isShowingCards: Bool { !entries.isEmpty }

    /// Shows a card on `screenFrame` (AppKit global), below any cards
    /// already there. The oldest card goes when there are too many.
    func show(_ card: DrawCard, on screenFrame: CGRect) {
        if entries.count >= Self.maximumCards, let oldest = entries.first {
            close(oldest.id)
        }
        let id = UUID()
        let model = DrawCardModel(card: card)
        let panel = Self.makePanel()
        let hosting = DrawCardHostingView(rootView: DrawCardView(model: model) { [weak self] in
            self?.close(id)
        })
        panel.contentView = hosting
        let visible = NSScreen.screens.first(where: { $0.frame == screenFrame })?.visibleFrame ?? screenFrame
        let size = Self.size(of: hosting)
        let below = entries
            .filter { visible.contains(CGPoint(x: $0.panel.frame.midX, y: $0.panel.frame.midY)) }
            .map(\.panel.frame.minY).min()
        let top = (below.map { $0 - Self.gap } ?? visible.maxY - 24)
        let origin = CGPoint(x: visible.maxX - size.width - 24, y: max(visible.minY + 24, top - size.height))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Animation.normal
            panel.animator().alphaValue = 1
        }
        entries.append(Entry(id: id, panel: panel, model: model))

        if let subject = card.photoSubject {
            Task { [weak self] in
                let url = await DrawCardPhotoLookup.thumbnailURL(for: subject)
                guard let self, let entry = self.entries.first(where: { $0.id == id }) else { return }
                entry.model.photo = url.map(DrawCardModel.Photo.found) ?? .none
                self.resizeKeepingTop(entry)
            }
        }
    }

    func close(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: index).panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Animation.fast
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

    func closeAll() {
        entries.map(\.id).forEach(close)
    }

    private func resizeKeepingTop(_ entry: Entry) {
        guard let hosting = entry.panel.contentView as? DrawCardHostingView else { return }
        let size = Self.size(of: hosting)
        let frame = entry.panel.frame
        entry.panel.setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                             display: true)
    }

    private static func size(of hosting: NSView) -> CGSize {
        hosting.frame = CGRect(x: 0, y: 0, width: cardWidth, height: 10)
        hosting.layoutSubtreeIfNeeded()
        return CGSize(width: cardWidth, height: ceil(hosting.fittingSize.height))
    }

    private static func makePanel() -> NSPanel {
        let panel = DrawCardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Drag the card anywhere by its body.
        panel.isMovableByWindowBackground = true
        return panel
    }
}

@MainActor
final class DrawCardModel: ObservableObject {
    enum Photo: Equatable {
        case loading
        case found(URL)
        case none
    }

    let card: DrawCard
    @Published var photo: Photo

    init(card: DrawCard) {
        self.card = card
        photo = card.photoSubject == nil ? .none : .loading
    }
}

private final class DrawCardHostingView: NSHostingView<DrawCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class DrawCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DrawCardView: View {
    @ObservedObject var model: DrawCardModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            photo
            HStack(alignment: .firstTextBaseline) {
                Text(model.card.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Spacing.sm)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close card")
            }
            ForEach(Array(model.card.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                    Text("•").foregroundColor(DS.Colors.textSecondary)
                    Text(line)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.Fonts.bodyLarge)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: DrawCardWindowController.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
    }

    @ViewBuilder
    private var photo: some View {
        switch model.photo {
        case .none:
            EmptyView()
        case .loading:
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
                .frame(height: DrawCardWindowController.photoHeight)
        case .found(let url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                DS.Colors.surface2
            }
            .frame(height: DrawCardWindowController.photoHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
    }
}

/// Finds a photo for a card subject: the lead image of the best-matching
/// English Wikipedia article. Free, keyless, and only the subject words
/// leave the Mac.
nonisolated enum DrawCardPhotoLookup {
    static let thumbnailWidth = 640

    static func searchURL(for subject: String) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: subject),
            URLQueryItem(name: "gsrlimit", value: "1"),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: String(thumbnailWidth)),
        ]
        return components?.url
    }

    /// The thumbnail in a `formatversion=2` pageimages response, if any.
    static func thumbnailURL(fromResponse data: Data) -> URL? {
        struct Response: Decodable {
            struct Query: Decodable { let pages: [Page] }
            struct Page: Decodable { let thumbnail: Thumbnail? }
            struct Thumbnail: Decodable { let source: String }
            let query: Query?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let source = response.query?.pages.first?.thumbnail?.source,
              let url = URL(string: source), url.scheme == "https" else { return nil }
        return url
    }

    static func thumbnailURL(for subject: String) async -> URL? {
        guard let url = searchURL(for: subject) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        // Wikimedia asks API clients to name themselves.
        request.setValue("HeyMate/1.0 (macOS companion; https://getheymate.vercel.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return thumbnailURL(fromResponse: data)
    }
}
