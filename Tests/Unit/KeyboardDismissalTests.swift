import CoreGraphics
import XCTest

final class KeyboardDismissalTests: XCTestCase {
    private func dismisses(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        KeyboardDismissal.isDismissSwipe(translation: CGSize(width: dx, height: dy))
    }

    func testThirtyPointsStraightDownDismisses() {
        XCTAssertEqual(KeyboardDismissal.minimumDistance, 30)
        XCTAssertTrue(dismisses(0, 30))
        XCTAssertTrue(dismisses(0, 240))
    }

    func testShorterDragsDoNot() {
        XCTAssertFalse(dismisses(0, 0))
        XCTAssertFalse(dismisses(0, 29.5))
        XCTAssertFalse(dismisses(-4, 12))
    }

    func testUpwardDragsDoNot() {
        XCTAssertFalse(dismisses(0, -30))
        XCTAssertFalse(dismisses(5, -200)) // flicking Quick Capture back into the island
    }

    func testMostlyDownWithSomeDriftDismisses() {
        XCTAssertTrue(dismisses(20, 40))
        XCTAssertTrue(dismisses(-29, 30))
    }

    func testHorizontalAndDiagonalSwipesDoNot() {
        XCTAssertFalse(dismisses(120, 40))  // paging to the next week
        XCTAssertFalse(dismisses(-80, 31))  // closing the drawer
        XCTAssertFalse(dismisses(-140, 10)) // a row's Delete
        XCTAssertFalse(dismisses(40, 40))   // exactly diagonal is not "mostly down"
    }
}
