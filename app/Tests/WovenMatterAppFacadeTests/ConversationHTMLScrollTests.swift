import AppKit
import CoreGraphics
import Testing
import WebKit
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ConversationHTMLScrollTests {
    @Test func embeddedArtifactWheelMovesTheOuterConversation() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = HTMLScrollSpy(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        let document = HTMLFlippedDocument(frame: NSRect(x: 0, y: 0, width: 680, height: 2000))
        scroll.documentView = document
        window.contentView = scroll
        let coordinator = ConversationHTMLWebCoordinator()
        let web = coordinator.makeWebView(forwardsConversationScroll: true)
        web.frame = NSRect(x: 0, y: 40, width: 680, height: 280)
        document.addSubview(web)
        defer { coordinator.stop(web); window.contentView = nil; window.close() }
        var ready = false
        coordinator.onReady = { ready = true }
        coordinator.apply(html: "<div style='height:240px'>A chart fixture</div>",
            theme: ConversationHTMLTheme.value(.green), to: web)
        for _ in 0..<400 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready)
        window.contentView?.layoutSubtreeIfNeeded()
        let event = try wheelEvent(window: window, web: web)
        let point = web.convert(NSPoint(x: 100, y: 100), to: scroll)
        let target = try #require(scroll.hitTest(point))
        let before = scroll.contentView.bounds.origin.y
        target.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.wheelEvents > 0, "WebKit swallowed the conversation's wheel event")
        #expect(scroll.contentView.bounds.origin.y > before, "Wheeling over the embedded visual reply did not move the transcript")

        // Chart zoom/pan modifiers and horizontal wheel gestures stay with
        // WebKit instead of being stolen by the transcript bridge.
        let count = scroll.wheelEvents
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            target.scrollWheel(with: try wheelEvent(window: window, web: web, flags: flags))
        }
        target.scrollWheel(with: try wheelEvent(window: window, web: web, horizontal: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.wheelEvents == count)

        // The expanded presentation keeps real browser scrolling. Listen in
        // the sandboxed child instead of weakening its cross-origin boundary.
        let native = try #require(web as? ConversationHTMLNativeWebView)
        native.forwardsConversationScroll = false
        ready = false
        coordinator.apply(html: """
            <div style='height:1600px'>Expanded content</div>
            <script>
            addEventListener('scroll',()=>console.log('fixture-scroll:'+scrollY));
            addEventListener('message',e=>{if(e.data?.kind==='fixture-scroll')scrollTo(0,240)});
            </script>
            """, theme: ConversationHTMLTheme.value(.green), to: web)
        for _ in 0..<400 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready)
        target.scrollWheel(with: try wheelEvent(window: window, web: web))
        try await Task.sleep(for: .milliseconds(200))
        #expect(scroll.wheelEvents == count, "Expanded page wheel was redirected to the transcript")
        // CGEvent-backed NSEvents have no window association, so WebKit does
        // not deliver this synthetic event into its child process. Verify its
        // unchanged native route above and real child scrolling separately.
        _ = try await web.evaluateJavaScript("document.getElementById('page').contentWindow.postMessage({kind:'fixture-scroll'},'*')")
        for _ in 0..<100 {
            if coordinator.consoleMessages.contains(where: { $0["text"] == "fixture-scroll:240" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.consoleMessages.contains { $0["text"] == "fixture-scroll:240" },
            "Expanded sandboxed browser content lost internal scrolling")
    }

    @Test func phasedGesturesKeepOneDestinationIncludingMomentum() throws {
        var router = ConversationHTMLScrollGesture()
        let vertical = try [
            phasedWheel(phase: 128),                         // mayBegin, no axis yet
            phasedWheel(phase: 1),                           // began, still no axis
            phasedWheel(y: -10, phase: 2),
            phasedWheel(x: -40, y: -1, phase: 2, flags: .maskControl),
            phasedWheel(phase: 4),                           // touch ended
            phasedWheel(momentum: 1),                        // momentum began, zero delta
            phasedWheel(x: -30, momentum: 2, flags: .maskShift),
            phasedWheel(momentum: 3),
        ]
        #expect(vertical[0].phase.contains(.mayBegin))
        #expect(vertical[1].phase.contains(.began))
        #expect(vertical[5].momentumPhase.contains(.began))
        #expect(vertical[7].momentumPhase.contains(.ended))
        #expect(router.deliveries(for: vertical[0], canForward: true).isEmpty)
        #expect(router.deliveries(for: vertical[1], canForward: true).isEmpty)
        let routed = vertical.dropFirst(2).flatMap { router.deliveries(for: $0, canForward: true) }
        #expect(routed.count == vertical.count)
        #expect(zip(routed, vertical).allSatisfy { $0.0.0 === $0.1 && $0.0.1 },
            "The vertical gesture lost its begin or switched destination mid-gesture")

        let horizontal = try [
            phasedWheel(x: -20, phase: 1),
            phasedWheel(y: -50, phase: 2),                    // axis changes must not reroute
            phasedWheel(phase: 4),
            phasedWheel(y: -10, momentum: 1),
            phasedWheel(momentum: 3),
        ]
        let retained = horizontal.flatMap { router.deliveries(for: $0, canForward: true) }
        #expect(retained.count == horizontal.count && retained.allSatisfy { !$0.1 })

        let modified = try [
            phasedWheel(y: -20, phase: 1, flags: .maskAlternate),
            phasedWheel(y: -20, phase: 2),
            phasedWheel(phase: 8),                           // cancelled
        ]
        #expect(modified.flatMap { router.deliveries(for: $0, canForward: true) }.allSatisfy { !$0.1 })
        let next = try phasedWheel(y: -20, phase: 1)
        #expect(router.deliveries(for: next, canForward: true).first?.1 == true)
        _ = router.deliveries(for: try phasedWheel(phase: 4), canForward: true)
        // No momentum follows this time. A new touch chooses a fresh route.
        #expect(router.deliveries(for: try phasedWheel(x: -20, phase: 1), canForward: true).first?.1 == false)
    }

    @Test func directionlessCancellationAndDiscreteWheelsDoNotLeakGestureState() throws {
        var router = ConversationHTMLScrollGesture()
        let pending = try phasedWheel(phase: 128)
        #expect(router.deliveries(for: pending, canForward: true).isEmpty)
        let cancelled = try phasedWheel(phase: 8)
        let output = router.deliveries(for: cancelled, canForward: true)
        #expect(output.count == 2 && output.allSatisfy { !$0.1 })
        #expect(output.first?.0 === pending && output.last?.0 === cancelled)
        for (x, y, expected) in [(Int32(0), Int32(-20), true), (-20, 0, false), (0, -20, true)] {
            #expect(router.deliveries(for: try phasedWheel(x: x, y: y), canForward: true).first?.1 == expected)
        }
    }

    private func phasedWheel(x: Int32 = 0, y: Int32 = 0, phase: Int64 = 0,
                             momentum: Int64 = 0, flags: CGEventFlags = []) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.flags = flags
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: event))
    }

    private func wheelEvent(window: NSWindow, web: WKWebView, flags: CGEventFlags = [], horizontal: Bool = false) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: horizontal ? 0 : -80, wheel2: horizontal ? -80 : 0, wheel3: 0))
        event.flags = flags
        event.location = window.convertPoint(toScreen: web.convert(NSPoint(x: 100, y: 100), to: nil))
        return try #require(NSEvent(cgEvent: event))
    }
}

@MainActor private final class HTMLFlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class HTMLScrollSpy: NSScrollView {
    var wheelEvents = 0
    override func scrollWheel(with event: NSEvent) {
        wheelEvents += 1
        super.scrollWheel(with: event)
    }
}
