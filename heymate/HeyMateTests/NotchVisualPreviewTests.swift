import AppKit
import SwiftUI
import Testing
@testable import HeyMate

/// Rendering smoke test: actual SwiftUI content, isolated preferences, no provider requests.
@MainActor
struct NotchVisualPreviewTests {
    @Test func usageAndDragShelfRender() throws {
        let defaults = UserDefaults(suiteName: "notch-preview-\(UUID())")!
        defaults.set(["codex", "claude", "cursor"], forKey: "heymate.notch.usageProviders.v1")
        for (index, provider) in NotchUsageProvider.allCases.enumerated() {
            let reading = NotchUsageReading(windows: [
                NotchUsageWindow(id: "session", title: "Session", usedPercent: [32, 68, 14][index], resetsAt: Date().addingTimeInterval(3600)),
                NotchUsageWindow(id: "weekly", title: "Weekly", usedPercent: [61, 44, 27][index], resetsAt: Date().addingTimeInterval(86400))
            ], fetchedAt: Date())
            defaults.set(try JSONEncoder().encode(reading), forKey: "heymate.notch.usage.\(provider.rawValue)")
        }
        let store = NotchUsageStore(defaults: defaults)
        let manager = CompanionManager()
        try render(NotchUsageView(companionManager: manager, store: store), name: "usage", size: CGSize(width: 680, height: 400))
        let shelfURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shelf-preview-\(UUID()).json")
        let shelf = NotchShelfStore(bookmarkFileURL: shelfURL)
        let center = NotchActivityCenter(userDefaults: defaults)
        center.shelfPresentation = .hungry
        try render(NotchShelfMouthView(center: center, shelf: shelf), name: "mouth", size: CGSize(width: 680, height: 320))
    }

    private func render(_ content: some View, name: String, size: CGSize) throws {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Color.black).preferredColorScheme(.dark))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        try data.write(to: URL(fileURLWithPath: "/tmp/heymate-notch-\(name).png"))
    }
}
