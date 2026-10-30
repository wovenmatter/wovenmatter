import AppKit
import SwiftUI

/// Only the empty board receives these events. Embedded editors retain native input.
struct DashboardCanvasInput: NSViewRepresentable {
    var pan: (CGSize) -> Void
    var zoom: (Double) -> Void
    var select: () -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.pan = pan; view.zoom = zoom; view.select = select }
    final class InputView: NSView {
        var pan: ((CGSize) -> Void)?
        var zoom: ((Double) -> Void)?
        var select: (() -> Void)?
        private var lastPoint: CGPoint?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self); lastPoint = convert(event.locationInWindow, from: nil); select?()
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let previous = lastPoint { pan?(CGSize(width: point.x - previous.x, height: point.y - previous.y)) }
            lastPoint = point
        }
        override func mouseUp(with event: NSEvent) { lastPoint = nil }
        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) { zoom?(exp(event.scrollingDeltaY * 0.01)) }
            else { pan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)) }
        }
        override func magnify(with event: NSEvent) { zoom?(1 + event.magnification) }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: pan?(CGSize(width: 80, height: 0))
            case 124: pan?(CGSize(width: -80, height: 0))
            case 125: pan?(CGSize(width: 0, height: -80))
            case 126: pan?(CGSize(width: 0, height: 80))
            default: super.keyDown(with: event)
            }
        }
    }
}
