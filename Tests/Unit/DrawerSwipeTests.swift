import CoreGraphics
import XCTest

/// The drawer's swipe-to-close (`DrawerSwipe`): only a sideways drag towards the edge begins it, so the drawer's List
/// keeps every vertical drag.
final class DrawerSwipeTests: XCTestCase {
    func testOnlyASidewaysDragTowardsTheEdgeBegins() {
        XCTAssertTrue(DrawerSwipe.begins(velocity: CGPoint(x: -300, y: 0)))
        XCTAssertTrue(DrawerSwipe.begins(velocity: CGPoint(x: -300, y: 120)))
        XCTAssertFalse(DrawerSwipe.begins(velocity: CGPoint(x: 300, y: 0)), "away from the edge")
        XCTAssertFalse(DrawerSwipe.begins(velocity: CGPoint(x: 0, y: -600)), "scrolling the list")
        XCTAssertFalse(DrawerSwipe.begins(velocity: CGPoint(x: -100, y: 400)), "mostly vertical")
        XCTAssertFalse(DrawerSwipe.begins(velocity: CGPoint(x: -200, y: -200)), "a diagonal tie stays the list's")
        XCTAssertFalse(DrawerSwipe.begins(velocity: .zero))
    }

    func testThePanelFollowsTheFingerTowardsTheEdgeOnly() {
        XCTAssertEqual(DrawerSwipe.offset(translation: -42), -42)
        XCTAssertEqual(DrawerSwipe.offset(translation: 0), 0)
        XCTAssertEqual(DrawerSwipe.offset(translation: 60), 0)
    }

    func testFarEnoughOrFastEnoughCloses() {
        XCTAssertEqual(DrawerSwipe.closeDistance, 80)
        XCTAssertTrue(DrawerSwipe.closes(translation: -81, velocity: 0))
        XCTAssertFalse(DrawerSwipe.closes(translation: -80, velocity: 0))
        XCTAssertFalse(DrawerSwipe.closes(translation: -40, velocity: -200))
        XCTAssertTrue(DrawerSwipe.closes(translation: -20, velocity: -900), "a flick")
        XCTAssertFalse(DrawerSwipe.closes(translation: -100 + 30, velocity: 300), "pulled back")
    }
}
