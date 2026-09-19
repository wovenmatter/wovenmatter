import AppKit
import SwiftUI

@main
struct DashboardConversationPopoverTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PopoverTestDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class PopoverTestDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var anchor: NSButton!
    var coordinator = DashboardConversationPopover<EmptyView>.Coordinator()
    var presented = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 250, width: 650, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Isolated Hover Motion Fixture"
        anchor = NSButton(title: "Conversation anchor", target: self, action: #selector(toggle))
        anchor.frame = NSRect(x: 25, y: 220, width: 200, height: 54)
        window.contentView!.addSubview(anchor)
        coordinator.host.rootView = AnyView(VStack(alignment: .leading, spacing: 10) {
            Text("Conversation hover details").font(.system(size: 13, weight: .semibold))
            Label("Workspace", systemImage: "folder")
            Label("Codex", systemImage: "terminal")
            Label("Local workspace agents", systemImage: "desktopcomputer")
            Divider()
            Text("Native arrow, material and shadow").font(.system(size: 11.5))
            Text("4:30 PM").font(.system(size: 10.5))
        }.padding(14).frame(width: 260, alignment: .leading))
        coordinator.isPresented = Binding(get: { self.presented }, set: { self.presented = $0 })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.exercise() }
    }
    @objc func toggle() {
        presented.toggle()
        coordinator.update(presented: presented, anchor: anchor)
    }
    func exercise() {
        Task { @MainActor in await verify() }
    }
    func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            print("FAIL: " + description); fflush(stdout); exit(1)
        }
        print("PASS: " + description); fflush(stdout)
    }
    func setPresented(_ value: Bool) {
        presented = value
        coordinator.update(presented: value, anchor: anchor)
    }
    func verify() async {
        verifyHoverOnlyState()
        setPresented(true)
        let surface = coordinator.host.view.window!
        let initialX = surface.frame.minX
        await pause(0.15)
        expect(surface.alphaValue > 0 && surface.alphaValue < 1, "opening animates actual window opacity")
        expect(surface.frame.minX > initialX, "opening moves actual window toward resting position")
        await pause(0.8)
        let restingX = surface.frame.minX
        expect(abs(surface.alphaValue - 1) < 0.01, "opening settles fully visible")
        setPresented(false)
        await pause(0.12)
        expect(coordinator.popover.isShown, "dismissal retains real popover while moving")
        expect(surface.alphaValue > 0 && surface.alphaValue < 1, "dismissal animates actual window opacity")
        expect(surface.frame.minX < restingX, "dismissal moves actual native chrome")
        setPresented(true)
        await pause(1)
        expect(coordinator.popover.isShown && presented, "reopening survives stale close completion")
        expect(abs(surface.frame.minX - restingX) < 1, "reopening returns to original anchor")
        setPresented(false)
        await pause(1)
        expect(!coordinator.popover.isShown, "dismissal eventually closes native window")
        setPresented(true)
        await pause(0.03)
        setPresented(false)
        await pause(1)
        expect(!coordinator.popover.isShown, "dismiss during opening cannot resurrect window")
        coordinator.reduceMotion = true
        setPresented(true)
        expect(coordinator.popover.isShown && surface.alphaValue == 1, "reduced motion opens immediately")
        setPresented(false)
        expect(!coordinator.popover.isShown, "reduced motion closes immediately")
        setPresented(true)
        await pause(0.05)
        expect(presented && coordinator.popover.isShown, "stale forced-close callback cannot clear reopen")
        coordinator.popover.performClose(nil)
        expect(!presented && !coordinator.popover.isShown, "native transient close synchronizes binding")
        setPresented(true)
        coordinator.popover.close()
        await pause(0.05)
        expect(!presented, "forced native close clears binding")
        setPresented(true)
        let beforeMove = surface.frame
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 40, y: window.frame.minY + 30))
        await pause(0.1)
        expect(abs(surface.frame.minX - beforeMove.minX - 40) < 1, "native anchor follows parent horizontally")
        expect(abs(surface.frame.minY - beforeMove.minY - 30) < 1, "native anchor follows parent vertically")
        setPresented(false)
        coordinator.reduceMotion = false
        setPresented(true)
        await pause(0.03)
        coordinator.tearDown()
        await pause(1)
        expect(!coordinator.popover.isShown, "teardown during opening cannot leave an orphan window")
        print("ALL POPOVER LIFECYCLE CHECKS PASSED"); fflush(stdout)
        NSApp.terminate(nil)
    }

    func verifyHoverOnlyState() {
        var details = DashboardConversationDetailCardState()
        details.completePrimaryAction()
        expect(details.presentedConversationID == nil, "primary activation without hover cannot present a preview")
        details.setHovered(true, conversationID: "a")
        details.completePrimaryAction()
        expect(details.presentedConversationID == nil, "primary activation dismisses an existing hover preview")
        details.setHovered(true, conversationID: "b")
        details.setHovered(false, conversationID: "a")
        details.remove(conversationID: "a")
        expect(details.presentedConversationID == "b", "old row exit and removal cannot dismiss the new preview")
        details.setHovered(false, conversationID: "b")
        expect(details.presentedConversationID == nil, "hover exit clears presentation immediately")

        let hover = DashboardScrollHoverCoordinator()
        var hoveredA = false
        var hoveredB = false
        hover.recordHover(true, token: "a") { hoveredA = $0 }
        expect(hoveredA, "first hover enters its row")
        hover.recordHover(true, token: "b") { hoveredB = $0 }
        expect(!hoveredA && hoveredB, "entry into a new row clears the old hover before its exit arrives")
        hover.recordHover(false, token: "a") { hoveredA = $0 }
        expect(hoveredB && hover.hoveredToken == "b", "late old-row exit preserves the current hover")
        hover.setScrolling(true)
        expect(!hoveredB, "scrolling immediately clears current hover")
        hover.setScrolling(false)
        expect(hoveredB, "ending scroll restores hover for a fresh appearance delay")
        hover.setScrolling(true)
        hover.recordHover(false, token: "b") { hoveredB = $0 }
        hover.setScrolling(false)
        expect(!hoveredB && hover.hoveredToken == nil, "leaving during scrolling cannot restore a stale hover")
        hover.recordHover(true, token: "a") { hoveredA = $0 }
        hover.setScrolling(true)
        hover.recordHover(true, token: "b") { hoveredB = $0 }
        hover.setScrolling(false)
        expect(!hoveredA && hoveredB, "hover transfer during scrolling resumes only the current row")
        hover.recordHover(false, token: "b") { hoveredB = $0 }
        expect(!hoveredB, "final exit clears the active row")
    }
}
