import SwiftUI
import XCTest
@testable import Luminore

final class AdaptiveLayoutTests: XCTestCase {
    private typealias Canvas = PhoneCanvas<EmptyView>

    func testPhoneIsLeftUntouched() {
        let layout = Canvas.layout(for: CGSize(width: 393, height: 700))
        XCTAssertEqual(layout.scale, 1)
        XCTAssertFalse(layout.isWide)
        XCTAssertEqual(layout.logical, CGSize(width: 393, height: 700))
    }

    func testLandscapeIPadUsesTwoColumnBoard() {
        let layout = Canvas.layout(for: CGSize(width: 1376, height: 1032))
        XCTAssertTrue(layout.isWide)
        XCTAssertGreaterThan(layout.scale, 1)
        XCTAssertGreaterThanOrEqual(layout.logical.width, AdaptiveLayout.wideBoardWidth)
        XCTAssertLessThanOrEqual(layout.logical.width, AdaptiveLayout.wideBoardMaxWidth)
        // The scaled canvas must cover the screen height exactly.
        XCTAssertEqual(layout.logical.height * layout.scale, 1032, accuracy: 0.5)
    }

    func testPortraitIPadScalesPhoneLayoutWithoutWideColumns() {
        let layout = Canvas.layout(for: CGSize(width: 1032, height: 1376))
        XCTAssertFalse(layout.isWide)
        XCTAssertGreaterThan(layout.scale, 1)
        XCTAssertLessThanOrEqual(layout.logical.width, AdaptiveLayout.designMaxWidth)
    }

    func testSmallIPadLandscapeNeverShrinksTheBoardBelowReadable() {
        let layout = Canvas.layout(for: CGSize(width: 1133, height: 744))
        XCTAssertTrue(layout.isWide)
        XCTAssertGreaterThanOrEqual(layout.scale, AdaptiveLayout.wideMinimumScale)
    }
}
