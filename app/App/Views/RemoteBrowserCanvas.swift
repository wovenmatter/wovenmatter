import AppKit
import SwiftUI
import WovenMatterClient

/// SwiftUI owns the session; this small AppKit surface owns native input and IME composition.
struct RemoteBrowserCanvas: NSViewRepresentable {
    let image: NSImage
    let tabID: String
    let frameID: String?
    let send: (RemoteBrowserAction) -> Void
    let focusAddress: () -> Void

    func makeNSView(context: Context) -> RemoteBrowserInputView { RemoteBrowserInputView() }
    func updateNSView(_ view: RemoteBrowserInputView, context: Context) {
        if view.tabID != tabID { view.resetInput(); view.tabID = tabID }
        if view.image !== image { view.image = image; view.needsDisplay = true }
        view.frameID = frameID; view.send = send; view.focusAddress = focusAddress
    }
    static func dismantleNSView(_ view: RemoteBrowserInputView, coordinator: ()) {
        view.resetInput(); view.send = { _ in }
    }
}

final class RemoteBrowserInputView: NSView, @preconcurrency NSTextInputClient {
    var image: NSImage?
    var tabID = ""
    var frameID: String?
    var send: (RemoteBrowserAction) -> Void = { _ in }
    var focusAddress: () -> Void = {}
    private var tracking: NSTrackingArea?
    private var pressed: RemoteBrowserAction?
    private var marked = NSAttributedString(string: "")
    private var lastMotion = TimeInterval.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func imageRect(image: NSSize, bounds: NSRect) -> NSRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = NSSize(width: image.width * scale, height: image.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var imageRect: NSRect { Self.imageRect(image: image?.size ?? .zero, bounds: bounds) }
    func normalizedPoint(_ point: NSPoint) -> NSPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return NSPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if hasMarkedText() {
            let label = NSAttributedString(string: marked.string, attributes: [.font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.windowBackgroundColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue])
            label.draw(at: NSPoint(x: imageRect.minX + 12, y: imageRect.maxY - 28))
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    func resetInput() {
        if var action = pressed { action.kind = "pointerCancel"; emit(action) }
        pressed = nil; unmarkText()
    }
    override func resignFirstResponder() -> Bool { resetInput(); return super.resignFirstResponder() }
    private func emit(_ gesture: RemoteBrowserAction) {
        var action = gesture
        action.tabID = tabID
        if action.frameID.isEmpty { action.frameID = frameID ?? "" }
        send(action)
    }
    private func modifiers(_ event: NSEvent) -> Int {
        // The remote browser runs Linux. Map Mac Command shortcuts to Control.
        (event.modifierFlags.contains(.option) ? 1 : 0)
        | (event.modifierFlags.intersection([.control, .command]).isEmpty ? 0 : 2)
        | (event.modifierFlags.contains(.shift) ? 8 : 0)
    }
    private func point(_ event: NSEvent) -> NSPoint? { normalizedPoint(convert(event.locationInWindow, from: nil)) }
    private func begin(_ event: NSEvent, button: String) {
        guard let point = point(event) else { return }
        resetInput(); window?.makeFirstResponder(self)
        var action = RemoteBrowserAction(kind: "pointerDown")
        action.gestureID = UUID().uuidString.lowercased(); action.frameID = frameID ?? ""
        action.x = point.x; action.y = point.y; action.button = button
        action.clickCount = min(3, max(1, event.clickCount)); action.modifiers = modifiers(event)
        pressed = action; emit(action)
    }
    private func continuePointer(_ event: NSEvent, release: Bool) {
        guard var action = pressed else { return }
        let rect = imageRect, location = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.height > 0 else { resetInput(); return }
        action.actionID = UUID().uuidString.lowercased()
        action.kind = release ? "pointerUp" : "pointerMove"
        // A release outside the image must still release the remote button.
        action.x = min(1, max(0, (location.x - rect.minX) / rect.width))
        action.y = min(1, max(0, (location.y - rect.minY) / rect.height))
        action.modifiers = modifiers(event)
        if release && !rect.contains(location) { action.kind = "pointerCancel" }
        if release { pressed = nil } else { pressed = action }
        emit(action)
    }
    override func mouseDown(with event: NSEvent) { begin(event, button: "left") }
    override func mouseUp(with event: NSEvent) { continuePointer(event, release: true) }
    override func mouseDragged(with event: NSEvent) { continuePointer(event, release: false) }
    override func rightMouseDown(with event: NSEvent) { begin(event, button: "right") }
    override func rightMouseUp(with event: NSEvent) { continuePointer(event, release: true) }
    override func rightMouseDragged(with event: NSEvent) { continuePointer(event, release: false) }
    override func mouseMoved(with event: NSEvent) {
        guard event.timestamp - lastMotion > 0.016, let point = point(event) else { return }
        lastMotion = event.timestamp
        var action = RemoteBrowserAction(kind: "move")
        action.x = point.x; action.y = point.y; action.modifiers = modifiers(event); emit(action)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let point = point(event) else { return }
        var action = RemoteBrowserAction(kind: "scroll")
        action.x = point.x; action.y = point.y; action.modifiers = modifiers(event)
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 30.0
        action.deltaX = max(-4000, min(4000, -event.scrollingDeltaX * scale))
        action.deltaY = max(-4000, min(4000, -event.scrollingDeltaY * scale))
        emit(action)
    }
    private func key(_ value: String, flags: Int = 0) {
        var action = RemoteBrowserAction(kind: "key"); action.key = value; action.modifiers = flags; emit(action)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              let value = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch value {
        case "v": paste(nil)
        case "c": copy(nil)
        case "a", "z": key(value, flags: modifiers(event))
        case "r": emit(.init(kind: "reload"))
        case "l": focusAddress()
        default: return false
        }
        return true
    }
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    @objc func copy(_ sender: Any?) { emit(.init(kind: "copy")) }
    @objc override func selectAll(_ sender: Any?) { key("a", flags: 2) }
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { interpretKeyEvents([event]); return }
        let special: [UInt16: String] = [36: "Enter", 76: "Enter", 48: "Tab", 53: "Escape", 51: "Backspace", 117: "Delete",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown"]
        if var name = special[event.keyCode] {
            var flags = modifiers(event)
            if event.modifierFlags.contains(.command), ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].contains(name) {
                name = ["ArrowLeft", "ArrowUp"].contains(name) ? "Home" : "End"
                if [123, 124].contains(event.keyCode) { flags &= ~2 }
            } else if event.modifierFlags.contains(.option), ["ArrowLeft", "ArrowRight", "Backspace", "Delete"].contains(name) {
                flags = (flags & ~1) | 2
            }
            key(name, flags: flags); return
        }
        if event.modifierFlags.contains(.control), let value = event.charactersIgnoringModifiers, value.count == 1 {
            key(value, flags: modifiers(event)); return
        }
        if event.modifierFlags.intersection([.option, .command]).isEmpty,
           let text = event.characters, text.utf8.count == 1,
           let scalar = text.unicodeScalars.first, (32...126).contains(scalar.value) {
            var action = RemoteBrowserAction(kind: "key"); action.key = text; action.text = text
            action.modifiers = modifiers(event); emit(action); return
        }
        interpretKeyEvents([event])
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        unmarkText()
        guard !text.isEmpty else { return }
        var action = RemoteBrowserAction(kind: "text"); action.text = text; emit(action)
    }
    override func doCommand(by selector: Selector) {
        let commands: [String: (String, Int)] = ["insertNewline:": ("Enter", 0), "insertTab:": ("Tab", 0),
            "insertBacktab:": ("Tab", 8), "deleteBackward:": ("Backspace", 0), "deleteForward:": ("Delete", 0),
            "deleteWordBackward:": ("Backspace", 2), "moveLeft:": ("ArrowLeft", 0), "moveRight:": ("ArrowRight", 0),
            "moveUp:": ("ArrowUp", 0), "moveDown:": ("ArrowDown", 0), "cancelOperation:": ("Escape", 0)]
        if let (name, flags) = commands[NSStringFromSelector(selector)] { key(name, flags: flags) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        needsDisplay = true
    }
    func unmarkText() { marked = NSAttributedString(string: ""); needsDisplay = true }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length) }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: imageRect.minX + 12, y: imageRect.maxY - 28, width: 1, height: 22), to: nil)) ?? .zero
    }
}
