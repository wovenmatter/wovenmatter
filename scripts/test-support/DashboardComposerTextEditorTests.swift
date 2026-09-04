import AppKit
import Foundation
import SwiftUI

@MainActor
private final class ScrollEventSpy: NSResponder {
    private(set) var eventCount = 0

    override func scrollWheel(with event: NSEvent) {
        eventCount += 1
    }
}

@MainActor
private final class FirstResponderWindowSpy: NSWindow {
    private(set) var resignationRequestCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder == nil {
            resignationRequestCount += 1
        }
        return super.makeFirstResponder(responder)
    }
}

@MainActor
private func keyEvent(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func scrollEvent(deltaY: Int32) -> NSEvent {
    let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    )!
    return NSEvent(cgEvent: cgEvent)!
}

@MainActor
private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard condition() else {
        fatalError("\(file):\(line): \(message)")
    }
}

@main
@MainActor
struct DashboardComposerTextEditorTests {
    static func main() {
        testShiftReturnReplacesSelectionWithoutSubmitting()
        testPlainReturnSubmitsWithoutEditing()
        testKeyRoutingPreservesMarkedTextAndStandardBindings()
        testCommandArrowPanelNavigationIsResponderScoped()
        testNativeArrowCaretMovement()
        testTabCompletionIsNarrowAndOptional()
        testSelectionAndPasteboardServicesRemainNative()
        testMultilineOverflowAndScrollRouting()
        testNativeFocusUpdatesTheBindingImmediately()
        testStaleBlurDoesNotCancelManualRefocus()
        print("Dashboard composer native text behavior passed.")
    }

    private static func testShiftReturnReplacesSelectionWithoutSubmitting() {
        let textView = DashboardComposerNativeTextView()
        var submitCount = 0
        textView.onSubmit = { submitCount += 1 }
        textView.string = "alpha beta"
        textView.setSelectedRange(NSRange(location: 6, length: 4))

        textView.keyDown(with: keyEvent(keyCode: 36, characters: "\r", modifiers: .shift))

        expect(textView.string == "alpha \n", "Shift-Return must replace the selected text with a newline")
        expect(textView.selectedRange() == NSRange(location: 7, length: 0), "newline insertion must leave a caret after the newline")
        expect(submitCount == 0, "Shift-Return must not submit")
    }

    private static func testPlainReturnSubmitsWithoutEditing() {
        let textView = DashboardComposerNativeTextView()
        var submitCount = 0
        textView.onSubmit = { submitCount += 1 }
        textView.string = "draft"
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        expect(textView.string == "draft", "plain Return must not change the draft")
        expect(textView.selectedRange() == NSRange(location: 2, length: 0), "plain Return must preserve selection")
        expect(submitCount == 1, "plain Return must submit exactly once")
    }

    private static func testKeyRoutingPreservesMarkedTextAndStandardBindings() {
        expect(
            DashboardComposerKeyAction.resolve(
                keyCode: 36,
                charactersIgnoringModifiers: "\r",
                modifierFlags: [],
                hasMarkedText: true
            ) == .standard,
            "Return must remain with the text system while IME marked text exists"
        )
        for keyCode: UInt16 in [125, 126] {
            expect(
                DashboardComposerKeyAction.resolve(
                    keyCode: keyCode,
                    charactersIgnoringModifiers: nil,
                    modifierFlags: [],
                    hasMarkedText: false
                ) == .standard,
                "Up/Down must keep native caret movement"
            )
            expect(
                DashboardComposerKeyAction.resolve(
                    keyCode: keyCode,
                    charactersIgnoringModifiers: nil,
                    modifierFlags: .command,
                    hasMarkedText: false
                ) == .standard,
                "Command-Up/Down must remain standard when panel navigation declines them"
            )
        }
        expect(
            DashboardComposerKeyAction.resolve(
                keyCode: 36,
                charactersIgnoringModifiers: "\r",
                modifierFlags: .option,
                hasMarkedText: false
            ) == .standard,
            "modified Return bindings other than Shift-Return must remain native"
        )

        let markedTextView = DashboardComposerNativeTextView()
        var submitCount = 0
        markedTextView.onSubmit = { submitCount += 1 }
        markedTextView.setMarkedText(
            "候補",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        expect(markedTextView.hasMarkedText(), "the IME test must establish marked text")
        expect(
            DashboardComposerKeyAction.resolve(
                keyCode: 36,
                charactersIgnoringModifiers: "\r",
                modifierFlags: [],
                hasMarkedText: markedTextView.hasMarkedText()
            ) == .standard,
            "the live marked-text state must route Return to the text system"
        )
        expect(submitCount == 0, "Return used by marked text must not submit")
    }

    private static func testCommandArrowPanelNavigationIsResponderScoped() {
        let textView = DashboardComposerNativeTextView()
        var navigations: [DashboardComposerNavigationDirection] = []
        textView.onCommandNavigation = { direction in
            navigations.append(direction)
            return true
        }

        textView.keyDown(with: keyEvent(
            keyCode: 124,
            characters: "\u{F703}",
            modifiers: .command
        ))
        expect(navigations == [.right], "Command-Right must reach the active panel navigator")
        expect(
            DashboardComposerNavigationDirection.resolve(
                keyCode: 126,
                modifierFlags: .command,
                hasMarkedText: false
            ) == .up,
            "Command-Up must map to panel navigation"
        )
        expect(
            DashboardComposerNavigationDirection.resolve(
                keyCode: 125,
                modifierFlags: [],
                hasMarkedText: false
            ) == nil,
            "plain arrows must remain native caret movement"
        )
        expect(
            DashboardComposerNavigationDirection.resolve(
                keyCode: 123,
                modifierFlags: .command,
                hasMarkedText: true
            ) == nil,
            "marked text must keep Command-arrow inside the text system"
        )
    }

    private static func testNativeArrowCaretMovement() {
        let textView = DashboardComposerNativeTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 240, height: 72)
        textView.string = "first line\nsecond line"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        let bottomLocation = textView.selectedRange().location
        textView.moveUp(nil)
        let upperLocation = textView.selectedRange().location
        expect(upperLocation < bottomLocation, "Up must use NSTextView caret navigation")
        textView.moveDown(nil)
        expect(textView.selectedRange().location > upperLocation, "Down must use NSTextView caret navigation")
    }

    private static func testTabCompletionIsNarrowAndOptional() {
        let textView = DashboardComposerNativeTextView()
        var completionCount = 0
        textView.onTab = {
            completionCount += 1
            return true
        }
        textView.keyDown(with: keyEvent(keyCode: 48, characters: "\t"))
        expect(completionCount == 1, "an available slash completion must consume unmodified Tab")

        textView.onTab = {
            completionCount += 1
            return false
        }
        textView.keyDown(with: keyEvent(keyCode: 48, characters: "\t", modifiers: .command))
        expect(completionCount == 1, "modified Tab must remain a standard responder-chain command")
    }

    private static func testSelectionAndPasteboardServicesRemainNative() {
        let textView = DashboardComposerNativeTextView()
        textView.string = "copy paste"
        textView.setSelectedRange(NSRange(location: 0, length: 4))

        expect(textView.isSelectable, "selection and copy must remain enabled")
        expect(textView.responds(to: #selector(NSText.copy(_:))), "NSTextView copy action must remain on the responder")
        expect(textView.responds(to: #selector(NSText.paste(_:))), "NSTextView paste action must remain on the responder")
        expect(textView.selectedRange() == NSRange(location: 0, length: 4), "the requested copy selection must remain intact")

        textView.setSelectedRange(NSRange(location: 5, length: 5))
        textView.insertText("copy", replacementRange: textView.selectedRange())
        expect(textView.string == "copy copy", "paste must replace the current selection")
        expect(textView.allowsUndo, "the native editor must retain undo support")
    }

    private static func testMultilineOverflowAndScrollRouting() {
        let compactView = DashboardComposerScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 1)
        )
        compactView.maximumVisibleLines = 3
        compactView.composerTextView.string = "one\ntwo\nthree\nfour"
        compactView.frame.size.height = compactView.preferredHeight
        compactView.updateDocumentLayout()
        expect(
            compactView.hasVerticalOverflow,
            "a compact composer must scroll after its third visible line"
        )

        let sevenLineView = DashboardComposerScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 1)
        )
        sevenLineView.composerTextView.string = "one\ntwo\nthree\nfour\nfive\nsix\nseven"
        sevenLineView.frame.size.height = sevenLineView.preferredHeight
        sevenLineView.updateDocumentLayout()
        expect(!sevenLineView.hasVerticalOverflow, "the composer must grow to show seven lines without scrolling")

        let scrollView = DashboardComposerScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        let spy = ScrollEventSpy()
        scrollView.nextResponder = spy

        scrollView.composerTextView.string = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine"
        let cappedHeight = scrollView.preferredHeight
        scrollView.frame.size.height = cappedHeight
        scrollView.updateDocumentLayout()
        expect(scrollView.preferredHeight > DashboardComposerScrollView.minimumHeight, "the composer must grow with multiline content")
        expect(cappedHeight < scrollView.composerTextView.frame.height, "content after seven lines must exceed the dynamic height cap")
        expect(scrollView.hasVerticalOverflow, "multiline content taller than the viewport must overflow internally")
        expect(scrollView.composerTextView.frame.height > scrollView.contentView.bounds.height, "the document view must grow beyond the capped viewport")
        let preciseScrollEvent = scrollEvent(deltaY: -12)
        expect(preciseScrollEvent.hasPreciseScrollingDeltas, "pixel wheel input must model trackpad routing")
        scrollView.scrollWheel(with: preciseScrollEvent)
        expect(spy.eventCount == 0, "wheel and trackpad deltas must stay in an overflowing composer")

        scrollView.composerTextView.string = "short"
        scrollView.updateDocumentLayout()
        expect(!scrollView.hasVerticalOverflow, "short content must not claim vertical scrolling")
        scrollView.scrollWheel(with: scrollEvent(deltaY: -12))
        expect(spy.eventCount == 1, "a non-scrolling composer must pass wheel events to its responder chain")
    }

    private static func testStaleBlurDoesNotCancelManualRefocus() {
        func editor(isFocused: Bool) -> DashboardComposerTextEditor {
            DashboardComposerTextEditor(
                text: .constant(""),
                isFocused: .constant(isFocused),
                placeholder: "Message Codex…",
                maximumVisibleLines: 3,
                onSubmit: {},
                onTab: { false },
                onCommandNavigation: { _ in false }
            )
        }

        let window = FirstResponderWindowSpy(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = DashboardComposerScrollView(frame: window.contentView!.bounds)
        window.contentView = scrollView
        let textView = scrollView.composerTextView
        let coordinator = editor(isFocused: false).makeCoordinator()

        expect(window.makeFirstResponder(textView), "the test editor must accept native focus")
        coordinator.parent = editor(isFocused: true)
        coordinator.applyFocusReconciliation(expectedFocused: false, for: textView)
        expect(
            window.firstResponder === textView,
            "a stale false binding must not cancel a mouse-driven native refocus"
        )
        expect(
            window.resignationRequestCount == 0,
            "a stale false binding must not request native editor resignation"
        )

        coordinator.parent = editor(isFocused: false)
        coordinator.applyFocusReconciliation(expectedFocused: false, for: textView)
        expect(
            window.resignationRequestCount == 1,
            "a confirmed false binding must still request native editor resignation"
        )
    }

    private static func testNativeFocusUpdatesTheBindingImmediately() {
        final class FocusBox {
            var value = false
        }

        let focus = FocusBox()
        let editor = DashboardComposerTextEditor(
            text: .constant(""),
            isFocused: Binding(
                get: { focus.value },
                set: { focus.value = $0 }
            ),
            placeholder: "Message Codex…",
            maximumVisibleLines: 3,
            onSubmit: {},
            onTab: { false },
            onCommandNavigation: { _ in false }
        )
        let coordinator = editor.makeCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = DashboardComposerScrollView(frame: window.contentView!.bounds)
        window.contentView = scrollView
        let textView = scrollView.composerTextView
        textView.onBecomeFirstResponder = {
            coordinator.parent.isFocused = true
        }

        expect(window.makeFirstResponder(textView), "the test editor must accept native focus")
        expect(
            focus.value,
            "native first-responder acquisition must synchronously update the SwiftUI focus binding"
        )
    }
}
