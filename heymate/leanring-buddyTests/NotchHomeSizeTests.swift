//
//  NotchHomeSizeTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct NotchHomeSizeTests {

    @Test func standardIsTheWideShallowCard() {
        #expect(NotchHomeSize.standard.width == NotchLayoutMath.expandedWidth)
        #expect(NotchHomeSize.standard.heightBelowHousing == NotchLayoutMath.expandedHeight)
        #expect(NotchHomeSize.standard.width > NotchHomeSize.standard.heightBelowHousing)
    }

    @Test func theRetiredTallDefaultReturnsToTheWideCard() {
        let defaults = UserDefaults(suiteName: "NotchHomeSizeTests.retired")!
        defaults.removePersistentDomain(forName: "NotchHomeSizeTests.retired")
        defaults.set("480.0,360.0", forKey: NotchHomeSize.storageKey)
        let size = NotchHomeSize.stored(userDefaults: defaults)
        #expect(size == NotchHomeSize.standard)
        let raw = defaults.string(forKey: NotchHomeSize.storageKey) ?? ""
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        #expect(parts == [680.0, 250.0])
        defaults.removePersistentDomain(forName: "NotchHomeSizeTests.retired")
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
}
