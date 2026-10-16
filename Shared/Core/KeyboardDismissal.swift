import CoreGraphics

/// When a drag puts the keyboard away. Owner's request: anywhere in the app, swiping down on the screen hides the
/// keyboard, and tapping a text field brings it back as usual.
///
/// A drag counts once it has gone at least `minimumDistance` down and further down than sideways, so a horizontal
/// swipe (week and day paging, a row's Delete, closing the drawer) never hides the keyboard, and neither does any
/// upward drag. The app's window-wide recognizer (App/Views/KeyboardDismissSwipe.swift) asks this as the finger moves;
/// it is pure so the hostless tests cover it.
enum KeyboardDismissal {
    /// Points the finger travels down before the keyboard goes.
    static let minimumDistance: CGFloat = 30

    /// `translation` is the drag so far, positive height = down.
    static func isDismissSwipe(translation: CGSize) -> Bool {
        translation.height >= minimumDistance && translation.height > abs(translation.width)
    }
}
