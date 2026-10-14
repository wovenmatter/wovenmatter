import SwiftUI
import UIKit

/// Observe outside taps without swallowing buttons, scrolling, or the editor's own gestures.
struct MobileKeyboardDismissal: UIViewRepresentable {
  func makeUIView(context: Context) -> DismissalView { DismissalView() }
  func updateUIView(_ view: DismissalView, context: Context) {}
  static func dismantleUIView(_ view: DismissalView, coordinator: ()) { view.detach() }

  final class DismissalView: UIView, UIGestureRecognizerDelegate {
    private weak var observedWindow: UIWindow?
    private lazy var tap: UITapGestureRecognizer = {
      let value = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
      value.cancelsTouchesInView = false; value.delegate = self
      return value
    }()
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard observedWindow !== window else { return }
      detach(); observedWindow = window; window?.addGestureRecognizer(tap)
    }
    func detach() { observedWindow?.removeGestureRecognizer(tap); observedWindow = nil }
    @objc private func dismissKeyboard() { observedWindow?.endEditing(false) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      var current: UIResponder? = touch.view
      while let responder = current {
        // System alerts own their text fields and action taps. Resigning their
        // editor here changes the alert layout during the action's touch and
        // can turn the first Create tap into keyboard dismissal alone.
        if responder is UIAlertController || responder is UITextField ||
            (responder as? UITextView)?.isEditable == true { return false }
        current = responder.next
      }
      return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  }
}
