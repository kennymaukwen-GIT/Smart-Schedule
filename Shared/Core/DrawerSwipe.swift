import CoreGraphics

/// Swiping the drawer towards the leading edge closes it. The drawer's window-wide pan recognizer
/// (`DrawerCloseSwipe` in App/Views/Navigation/CalendarDrawer.swift) asks this as the finger moves; it is pure so the
/// hostless tests cover it.
///
/// The swipe is a UIKit recognizer, not a SwiftUI `DragGesture` on the drawer: a SwiftUI drag attached over the
/// drawer's List (`.simultaneousGesture(…, including: .all)`) has known gesture regressions on iOS 18 and the iOS 26
/// SDK, and was the first suspect when the drawer froze at its first scroll on an iPhone (2026-10-17). Vertical
/// drags are never this swipe's, so the List keeps them.
enum DrawerSwipe {
    /// Points the panel travels towards the edge before letting go closes it.
    static let closeDistance: CGFloat = 80
    /// Points per second of a flick towards the edge that closes it however short.
    static let closeSpeed: CGFloat = 500

    /// Whether a pan may begin: towards the leading edge, and more sideways than vertical.
    static func begins(velocity: CGPoint) -> Bool {
        velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    /// How far the panel follows the finger: towards the edge only.
    static func offset(translation: CGFloat) -> CGFloat {
        min(0, translation)
    }

    /// Whether letting go closes the drawer.
    static func closes(translation: CGFloat, velocity: CGFloat) -> Bool {
        translation < -closeDistance || velocity < -closeSpeed
    }
}
