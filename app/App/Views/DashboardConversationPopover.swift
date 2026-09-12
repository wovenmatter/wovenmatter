import AppKit
import SwiftUI

/// Retains native popover chrome and placement while animating the actual window.
/// SwiftUI's `.popover` does not expose its presentation/dismissal animation.
struct DashboardConversationPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.reduceMotion = reduceMotion
        coordinator.preferredEdge = environment.layoutDirection == .rightToLeft ? .minX : .maxX
        if isPresented || coordinator.popover.isShown {
            coordinator.host.rootView = AnyView(content().environment(\.self, environment))
        }
        coordinator.update(presented: isPresented, anchor: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        lazy var host = NSHostingController(rootView: AnyView(EmptyView()))
        var isPresented: Binding<Bool> = .constant(false)
        var reduceMotion = false
        var preferredEdge: NSRectEdge = .maxX
        private var closing = false
        private var opening = false
        private var motionOffset: CGFloat = -8
        private var generation = 0
        private var restingFrame: NSRect = .zero
        private var hiddenFrame: NSRect = .zero

        override init() {
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
        }

        func update(presented: Bool, anchor: NSView) {
            if presented {
                if popover.isShown {
                    if closing { animate(visible: true) }
                    return
                }
                guard let parentWindow = anchor.window, !anchor.visibleRect.isEmpty else { return }
                popover.contentViewController = host
                popover.appearance = anchor.effectiveAppearance
                host.view.layoutSubtreeIfNeeded()
                popover.contentSize = host.view.fittingSize
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
                guard let window = host.view.window, popover.isShown else { return }
                restingFrame = window.frame
                // Move toward the anchor, including when AppKit flips to the left
                // at a screen edge. The entire native surface moves, arrow included.
                let anchorFrame = parentWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                motionOffset = restingFrame.midX >= anchorFrame.midX ? -8 : 8
                hiddenFrame = restingFrame.offsetBy(dx: motionOffset, dy: 0)
                if !reduceMotion {
                    window.alphaValue = 0
                    window.setFrame(hiddenFrame, display: false)
                }
                animate(visible: true)
            } else if popover.isShown, !closing {
                dismiss()
            }
        }

        private func dismiss() {
            // Only a settled surface can supply a new native anchor position.
            // During an interrupted opening, keep the original destination.
            if !opening {
                restingFrame = host.view.window?.frame ?? restingFrame
                hiddenFrame = restingFrame.offsetBy(dx: motionOffset, dy: 0)
            }
            animate(visible: false)
        }

        private func animate(visible: Bool) {
            guard let window = host.view.window else { return }
            generation += 1
            let currentGeneration = generation
            closing = !visible
            opening = visible
            window.ignoresMouseEvents = !visible
            let changes = {
                window.animator().alphaValue = visible ? 1 : 0
                window.animator().setFrame(visible ? self.restingFrame : self.hiddenFrame, display: true)
            }
            let completion = { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.opening = false
                if !visible { self.popover.close() }
            }
            if reduceMotion {
                window.alphaValue = visible ? 1 : 0
                window.setFrame(restingFrame, display: true)
                completion()
            } else {
                // Unlike a modifier on hosted content, this animates NSWindow's
                // frame and alpha, and keeps it alive until dismissal completes.
                NSAnimationContext.animate(.snappy(duration: 0.3), changes: changes, completion: completion)
            }
        }

        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            isPresented.wrappedValue = false
            if !closing { dismiss() }
            return false
        }

        func popoverDidClose(_ notification: Notification) {
            generation += 1
            closing = false
            // Forced native closure (for example, a parent window closing) must
            // also clear SwiftUI state. Avoid mutating it during a view update.
            let currentGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.isPresented.wrappedValue = false
            }
        }

        func tearDown() {
            generation += 1
            popover.delegate = nil
            popover.close()
        }
    }
}
