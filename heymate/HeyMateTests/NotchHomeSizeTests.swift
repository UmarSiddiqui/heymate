//
//  NotchHomeSizeTests.swift
//  HeyMateTests
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct NotchHomeSizeTests {

    @Test func standardIsTheWideShallowCard() {
        #expect(NotchHomeSize.standard.width == NotchLayoutMath.expandedWidth)
        #expect(NotchHomeSize.standard.heightBelowHousing == NotchLayoutMath.expandedHeight)
        #expect(NotchHomeSize.standard.width > NotchHomeSize.standard.heightBelowHousing)
    }

    @Test func theCompactCardIsSmallerThanTheDoorTileCard() {
        #expect(NotchHomeSize.standard == NotchHomeSize(width: 600, heightBelowHousing: 164))
        #expect(NotchHomeSize.standard.heightBelowHousing < 250 * 0.7)
        #expect(NotchHomeSize.standard.width < 680)
        // The standard size survives its own clamp, so a reset lands on it.
        #expect(NotchHomeSize.standard.clamped() == NotchHomeSize.standard)
    }

    @Test(arguments: ["480.0,360.0", "680.0,250.0"])
    func aRetiredAutomaticSizeReturnsToTheCompactCard(saved: String) {
        let suite = "NotchHomeSizeTests.retired"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: NotchHomeSize.storageKey)
        let size = NotchHomeSize.stored(userDefaults: defaults)
        #expect(size == NotchHomeSize.standard)
        let raw = defaults.string(forKey: NotchHomeSize.storageKey) ?? ""
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        #expect(parts == [600.0, 164.0])
    }

    @Test func compactChatKeepsRoomForMessagesWhenHomeIsSmall() {
        let chat = NotchHomeSize.standard.atLeast(NotchHomeSize.compactChatMinimum)
        #expect(chat == NotchHomeSize.compactChatMinimum)
        let dragged = NotchHomeSize(width: 900, heightBelowHousing: 400)
        #expect(dragged.atLeast(NotchHomeSize.compactChatMinimum) == dragged)
    }

    @Test func aDraggedSizeIsKept() {
        let defaults = UserDefaults(suiteName: "NotchHomeSizeTests.custom")!
        defaults.removePersistentDomain(forName: "NotchHomeSizeTests.custom")
        defaults.set("900,400", forKey: NotchHomeSize.storageKey)
        let size = NotchHomeSize.stored(userDefaults: defaults)
        #expect(size.width == 900)
        #expect(size.heightBelowHousing == 400)
        defaults.removePersistentDomain(forName: "NotchHomeSizeTests.custom")
    }

    @Test func theFullChatKeepsItsOwnBiggerSize() {
        let suite = "NotchHomeSizeTests.chat"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NotchHomeSize.storedChat(userDefaults: defaults) == NotchHomeSize.Chat.standard)
        NotchHomeSize(width: 1400, heightBelowHousing: 900).saveChat(userDefaults: defaults)
        #expect(NotchHomeSize.storedChat(userDefaults: defaults) == NotchHomeSize(width: 1400, heightBelowHousing: 900))
        // The chat size never touches Home's.
        #expect(NotchHomeSize.stored(userDefaults: defaults) == .standard)
    }

    @Test func chatResizeIsClampedToChatBoundsNotHomes() {
        let grown = NotchHomeSize.Chat.standard
            .unclampedApplying(edge: .bottomRight, translation: CGSize(width: 400, height: 300))
            .clampedForChat()
        #expect(grown.width > NotchHomeSize.maximum.width)
        let shrunk = NotchHomeSize.Chat.standard
            .unclampedApplying(edge: .bottom, translation: CGSize(width: 0, height: -2000))
            .clampedForChat()
        #expect(shrunk.heightBelowHousing == NotchHomeSize.Chat.minimum.heightBelowHousing)
    }
    @Test func attachedDesktopResizeKeepsNotchAnchor() {
        let screen = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let requested = AttachedDesktopLayout.standard.unclampedApplying(
            edge: .bottomRight, translation: CGSize(width: 90, height: 40)
        )
        let frame = AttachedDesktopLayout.frame(screen: screen, requested: requested, neckHeight: 42)
        #expect(frame.width == 1340)
        #expect(frame.height == 822)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func attachedDesktopResizeFitsSmallDisplays() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = AttachedDesktopLayout.frame(screen: screen, requested: .init(width: 4000, heightBelowHousing: 3000), neckHeight: 42)
        #expect(frame.width == 760)
        #expect(frame.height == 540)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func attachedDesktopRestoresResizeAndRejectsInvalidSavedSize() {
        let suite = "NotchHomeSizeTests.attachedDesktop"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = NotchHomeSize(width: 1050, heightBelowHousing: 700)
        AttachedDesktopLayout.save(custom, defaults: defaults)
        #expect(AttachedDesktopLayout.storedSize(defaults: defaults) == custom)
        defaults.set("nan,-20", forKey: AttachedDesktopLayout.storageKey)
        #expect(AttachedDesktopLayout.storedSize(defaults: defaults) == AttachedDesktopLayout.standard)
    }

}
