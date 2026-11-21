import SwiftUI
import UIKit

/// Observe outside taps without swallowing buttons, scrolling, or the editor's own gestures.
struct MobileKeyboardDismissal: UIViewRepresentable {
  func makeUIView(context: Context) -> DismissalView { DismissalView() }
  func updateUIView(_ view: DismissalView, context: Context) {}
  static func dismantleUIView(_ view: DismissalView, coordinator: ()) { view.detach() }

  /// Live views marked with `keepsKeyboard()`; taps inside them never dismiss.
  @MainActor static let keepers = NSHashTable<UIView>.weakObjects()
  /// Whether a tap at this window location lands on a control that keeps the keyboard.
  @MainActor static func keepsKeyboard(at point: CGPoint, in window: UIWindow) -> Bool {
    keepers.allObjects.contains { $0.window === window && $0.convert($0.bounds, to: window).contains(point) }
  }

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
      // Controls that act on the text being edited, such as note undo, keep the
      // keyboard; their action runs after this tap and continues the editing.
      if let window = observedWindow, MobileKeyboardDismissal.keepsKeyboard(at: touch.location(in: window), in: window) { return false }
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

extension View {
  /// Taps on this view do not dismiss the keyboard, for controls that edit the focused text.
  func keepsKeyboard() -> some View { background(MobileKeyboardKeeper()) }
}

private struct MobileKeyboardKeeper: UIViewRepresentable {
  func makeUIView(context: Context) -> KeeperView { KeeperView() }
  func updateUIView(_ view: KeeperView, context: Context) {}
  final class KeeperView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { MobileKeyboardDismissal.keepers.add(self) } else { MobileKeyboardDismissal.keepers.remove(self) }
    }
  }
}
