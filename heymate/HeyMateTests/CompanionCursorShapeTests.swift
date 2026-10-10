import SwiftUI
import XCTest
@testable import HeyMate

final class CompanionCursorShapeTests: XCTestCase {
    func testShapeFillsArrowheadFlanksButLeavesShaftNotchOpen() {
        let path = CompanionCursorShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertTrue(path.contains(CGPoint(x: 16, y: 82)))
        XCTAssertTrue(path.contains(CGPoint(x: 84, y: 82)))
        XCTAssertFalse(path.contains(CGPoint(x: 50, y: 86)))
    }

    func testShapeScalesInsideProvidedBounds() {
        let bounds = CGRect(x: 20, y: 30, width: 40, height: 60)
        let pathBounds = CompanionCursorShape().path(in: bounds).boundingRect

        XCTAssertGreaterThanOrEqual(pathBounds.minX, bounds.minX)
        XCTAssertGreaterThanOrEqual(pathBounds.minY, bounds.minY)
        XCTAssertLessThanOrEqual(pathBounds.maxX, bounds.maxX)
        XCTAssertLessThanOrEqual(pathBounds.maxY, bounds.maxY)
    }
}
