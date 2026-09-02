import SwiftUI
import XCTest
@testable import Luminore

/// The countdown ring has to run **counter-clockwise from 12 o'clock**, and that
/// is the one thing about it impossible to check by reading the code: SwiftUI's
/// arc `clockwise` flag is inverted relative to what it draws, because y grows
/// downward. These walk the trimmed path and check where it actually goes.
@MainActor
final class MiningRingShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 300, height: 600)
    private let radius: CGFloat = 56

    /// Straight runs + four quarter-circles.
    private var perimeter: CGFloat {
        2 * (rect.width - 2 * radius) + 2 * (rect.height - 2 * radius) + 2 * .pi * radius
    }

    func testThePathStartsAtTheTopMidpoint() throws {
        let path = MiningRingShape(cornerRadius: radius).path(in: rect)
        let start = try XCTUnwrap(path.trimmedPath(from: 0, to: 0.001).currentPoint)
        XCTAssertEqual(start.y, rect.minY, accuracy: 1)
        XCTAssertEqual(start.x, rect.midX, accuracy: 4)
    }

    /// A quarter of the way round, counter-clockwise, is the middle of the *left*
    /// edge. Clockwise it would be the right edge instead.
    func testAQuarterOfTheWayRoundIsTheLeftEdge() throws {
        let path = MiningRingShape(cornerRadius: radius).path(in: rect)
        let point = try XCTUnwrap(path.trimmedPath(from: 0, to: 0.25).currentPoint)
        XCTAssertEqual(point.x, rect.minX, accuracy: 2, "counter-clockwise means left first")
        XCTAssertEqual(point.y, rect.midY, accuracy: 3)
    }

    /// Halfway round is the bottom midpoint. This also catches an arc that sweeps
    /// the long way (270° instead of 90°), which would stretch the path and put
    /// the halfway mark somewhere else entirely.
    func testHalfwayRoundIsTheBottomMidpoint() throws {
        let path = MiningRingShape(cornerRadius: radius).path(in: rect)
        let point = try XCTUnwrap(path.trimmedPath(from: 0, to: 0.5).currentPoint)
        XCTAssertEqual(point.x, rect.midX, accuracy: 3)
        XCTAssertEqual(point.y, rect.maxY, accuracy: 2)
    }

    func testThePathStaysInsideItsRectAndClosesTheLoop() throws {
        let path = MiningRingShape(cornerRadius: radius).path(in: rect)
        XCTAssertEqual(path.boundingRect.minX, rect.minX, accuracy: 1)
        XCTAssertEqual(path.boundingRect.maxX, rect.maxX, accuracy: 1)
        XCTAssertEqual(path.boundingRect.minY, rect.minY, accuracy: 1)
        XCTAssertEqual(path.boundingRect.maxY, rect.maxY, accuracy: 1)
        let end = try XCTUnwrap(path.currentPoint)
        XCTAssertEqual(end.x, rect.midX, accuracy: 1)
        XCTAssertEqual(end.y, rect.minY, accuracy: 1)
    }

    /// A corner radius larger than the box would otherwise fold the path inside
    /// out; it is clamped to half the shorter side.
    func testAnOversizedCornerRadiusIsClamped() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = MiningRingShape(cornerRadius: 400).path(in: square)
        XCTAssertEqual(path.boundingRect.width, square.width, accuracy: 1)
        XCTAssertEqual(path.boundingRect.height, square.height, accuracy: 1)
    }
}
