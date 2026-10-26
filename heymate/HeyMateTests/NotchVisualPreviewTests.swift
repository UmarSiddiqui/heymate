import AppKit
import SwiftUI
import Testing
@testable import HeyMate

/// Rendering smoke test: actual SwiftUI content, isolated preferences, no provider requests.
@MainActor
struct NotchVisualPreviewTests {
    @Test func fullChatWindowHasOneContinuousGradientWithoutTopRim() throws {
        let transition = NotchSurfaceTransitionModel()
        transition.showWithoutAnimation()
        let size = CGSize(width: 1000, height: 700)
        let bitmap = try render(NotchCompactChatCard(
            companionManager: CompanionManager(), occludedTopInset: 32,
            layoutSize: size, hardwareNotchWidth: 200,
            transitionModel: transition, isFullChat: true, onClose: {}
        ), name: "full-chat-neck", size: size)
        let scaleX = CGFloat(bitmap.pixelsWide) / size.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / size.height
        func gray(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let color = try #require(bitmap.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let top = try gray(500, 4)
        let middle = try gray(980, 350)
        let bottom = try gray(980, 650)
        #expect(top < 0.01)
        #expect(middle > top + 0.02)
        #expect(bottom > middle + 0.02)
        #expect(abs(bottom - CGFloat(30.0 / 255)) < 0.02)
        // Sidebar and conversation share the same global fade.
        let railMiddle = try gray(8, 350)
        #expect(abs(railMiddle - middle) < 0.01)
        // Top horizontal shoulder used to get a light 0.6 pt outline.
        let shoulder = try gray(200, 42)
        let belowShoulder = try gray(200, 45)
        #expect(abs(shoulder - belowShoulder) < 0.02)
    }

    @Test func usageAndDragShelfRender() throws {
        let suite = "notch-preview-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["codex", "claude", "cursor"], forKey: "heymate.notch.usageProviders.v1")
        for (index, provider) in [NotchUsageProvider.codex, .claude, .cursor].enumerated() {
            let reading = NotchUsageReading(windows: [
                NotchUsageWindow(id: "session", title: "Session", usedPercent: [32, 68, 14][index], resetsAt: Date().addingTimeInterval(3600)),
                NotchUsageWindow(id: "weekly", title: "Weekly", usedPercent: [61, 44, 27][index], resetsAt: Date().addingTimeInterval(86400))
            ], fetchedAt: Date())
            defaults.set(try JSONEncoder().encode(reading), forKey: "heymate.notch.usage.\(provider.rawValue)")
        }
        let store = NotchUsageStore(defaults: defaults)
        let manager = CompanionManager()
        for width in [CGFloat(440), CGFloat(600)] {
            try render(NotchUsageView(companionManager: manager, store: store), name: "usage-\(Int(width))", size: CGSize(width: width, height: 96))
            for provider in NotchUsageProvider.allCases {
                try render(NotchUsageView(companionManager: manager, store: store, initialProvider: provider), name: "usage-\(provider.rawValue)-\(Int(width))", size: CGSize(width: width, height: 96))
            }
        }
        try render(NotchCompactUsage(store: store), name: "idle-rings", size: CGSize(width: 73, height: 32))
        for width in [CGFloat(84), CGFloat(190)] {
            for tab in NotchExpandedTab.allCases {
                try render(NotchTabSwitcher(selectedTab: .constant(tab)), name: "tabs-\(tab.rawValue)-\(Int(width))", size: CGSize(width: width, height: 32))
            }
        }
        let shelfURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shelf-preview-\(UUID()).json")
        let shelf = NotchShelfStore(bookmarkFileURL: shelfURL)
        let center = NotchActivityCenter(userDefaults: defaults)
        center.shelfPresentation = .hungry
        try render(NotchShelfMouthView(center: center, shelf: shelf), name: "mouth", size: CGSize(width: 680, height: 320))
    }

    @Test func homeKeepsUsageNavigationWhileKeyboardPermissionsAreMissing() async throws {
        let guide = PermissionGuide(statusProvider: { permission in
            permission != .inputMonitoring && permission != .accessibility
        })
        await guide.refresh()
        #expect(!guide.isGranted(.inputMonitoring))
        #expect(!guide.isGranted(.accessibility))
        let manager = CompanionManager()
        let previousOnboarding = UserDefaults.standard.object(forKey: "hasCompletedOnboarding")
        manager.hasCompletedOnboarding = true
        defer {
            if let previousOnboarding { UserDefaults.standard.set(previousOnboarding, forKey: "hasCompletedOnboarding") }
            else { UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding") }
        }
        for width in [CGFloat(440), CGFloat(600)] {
            let transition = NotchSurfaceTransitionModel()
            transition.showWithoutAnimation()
            let size = CGSize(width: width, height: 32 + (width == 440 ? 140 : 164))
            try render(NotchExpandedView(
                companionManager: manager,
                occludedTopInset: 32,
                layoutSize: size,
                hardwareNotchWidth: 220,
                transitionModel: transition,
                initialTab: .home,
                permissionGuide: guide,
                onClose: {}
            ), name: "home-permission-warning-\(Int(width))", size: size)
        }
    }

    @discardableResult
    private func render(_ content: some View, name: String, size: CGSize) throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Color.black).preferredColorScheme(.dark))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        try data.write(to: URL(fileURLWithPath: "/tmp/heymate-notch-\(name).png"))
        return bitmap
    }
}
