import SwiftUI
import UIKit

/// Swipe down anywhere to hide the keyboard; tapping a text field brings it back as usual.
///
/// One `UIPanGestureRecognizer` on the app's window covers the main screen, Quick Capture, the drawer and every sheet
/// (sheets are presented in the same window), so nothing has to be added screen by screen. It only watches: it
/// recognizes alongside every other gesture, never cancels or delays their touches, and only begins while the keyboard
/// is up. The conversation's handle, the drawer's swipe, scrolling, paging, row swipes and pulling a sheet down all
/// carry on as before; a drag that `KeyboardDismissal.isDismissSwipe` accepts also hides the keyboard, once per drag.
/// A drag that starts inside the field being typed in is left to the field (caret, selection, a long note).
///
/// Next to it, the conversations scroll with `.scrollDismissesKeyboard(.interactively)` (the keyboard can follow the
/// finger down, as in Messages) and the sideways pagers with `.never` (paging keeps the keyboard up).
extension View {
    /// Installs the recognizer on the window this view is in. RootView applies it once.
    func dismissesKeyboardOnSwipeDown() -> some View {
        background(KeyboardSwipeHost().allowsHitTesting(false).accessibilityHidden(true))
    }
}

extension KeyboardDismissal {
    /// Hides the keyboard of whichever field has it (opening the drawer does this).
    @MainActor
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardSwipeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    /// Moves the recognizer to whichever window it is in, and takes it off when it leaves.
    final class HostView: UIView {
        private let swipe = KeyboardSwipeRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            swipe.attach(to: window)
        }
    }
}

/// The window's pan recognizer and its delegate (a recognizer does not keep its target or delegate alive; the host
/// view keeps this).
private final class KeyboardSwipeRecognizer: NSObject, UIGestureRecognizerDelegate {
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        return pan
    }()
    private var isObservingKeyboard = false
    private var isKeyboardUp = false
    /// The keyboard already went during this drag.
    private var hasDismissed = false

    func attach(to window: UIWindow?) {
        pan.view?.removeGestureRecognizer(pan)
        window?.addGestureRecognizer(pan)
        guard !isObservingKeyboard else { return }
        isObservingKeyboard = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        isKeyboardUp = true
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        isKeyboardUp = false
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { hasDismissed = false }
        guard pan.state == .began || pan.state == .changed, !hasDismissed, let window = pan.view else { return }
        let travel = pan.translation(in: window)
        guard KeyboardDismissal.isDismissSwipe(translation: CGSize(width: travel.x, height: travel.y)) else { return }
        hasDismissed = true
        window.endEditing(true)
    }

    // MARK: UIGestureRecognizerDelegate

    /// With the keyboard down the recognizer stays out of the way entirely.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isKeyboardUp
    }

    /// Always alongside, never instead of, whatever the touched view does with the drag.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// A touch inside the field being typed in belongs to the field.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current.isFirstResponder { return false }
            view = current.superview
        }
        return true
    }
}
