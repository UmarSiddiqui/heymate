import SwiftUI
import XCTest
@testable import HeyMate

final class BrandAppearanceTests: XCTestCase {
    func testLightAppearanceUsesWhiteBase() {
        XCTAssertEqual(BrandAppearance.iconAssetName(for: .light), "BrandIconLight")
        XCTAssertEqual(BrandAppearance.nebulaAssetName(for: .light), "BrandNebulaLight")
        XCTAssertEqual(BrandAppearance.baseColor(for: .light), Color.white)
    }

    func testDarkAppearanceUsesBlackBase() {
        XCTAssertEqual(BrandAppearance.iconAssetName(for: .dark), "BrandIconDark")
        XCTAssertEqual(BrandAppearance.nebulaAssetName(for: .dark), "BrandNebulaDark")
        XCTAssertEqual(BrandAppearance.baseColor(for: .dark), Color.black)
    }
}
