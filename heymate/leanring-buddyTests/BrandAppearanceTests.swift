import SwiftUI
import XCTest
@testable import HeyMate

final class BrandAppearanceTests: XCTestCase {
    func testLightAppearanceUsesBlueArtwork() {
        XCTAssertEqual(BrandAppearance.iconAssetName(for: .light), "BrandIconLight")
        XCTAssertEqual(BrandAppearance.nebulaAssetName(for: .light), "BrandNebulaLight")
        XCTAssertEqual(BrandAppearance.baseColor(for: .light), Color(hex: "#061A63"))
    }

    func testDarkAppearanceUsesBlackPurpleArtwork() {
        XCTAssertEqual(BrandAppearance.iconAssetName(for: .dark), "BrandIconDark")
        XCTAssertEqual(BrandAppearance.nebulaAssetName(for: .dark), "BrandNebulaDark")
        XCTAssertEqual(BrandAppearance.baseColor(for: .dark), Color.black)
    }
}
