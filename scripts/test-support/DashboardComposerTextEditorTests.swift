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
        testAttachmentPasteLeavesTextUntouched()
        testShiftReturnReplacesSelectionWithoutSubmitting()
        testPlainReturnSubmitsWithoutEditing()
        testKeyRoutingPreservesMarkedTextAndStandardBindings()
        testCommandArrowPanelNavigationIsResponderScoped()
        testNativeArrowCaretMovement()
        testTabCompletionIsNarrowAndOptional()
        testPickerNavigationIsNarrowAndOptional()
        testCompletionMovesCaretWithoutChangingOrdinarySelection()
        testTypingBeforeSwiftUIAppliesCompletion()
        testCaretReportsUseTheLatestNativeSelection()
        testSelectionAndPasteboardServicesRemainNative()
        testMultilineOverflowAndScrollRouting()
        testNativeFocusUpdatesTheBindingImmediately()
        testStaleBlurDoesNotCancelManualRefocus()
        print("Dashboard composer native text behavior passed.")
    }

    private static func testAttachmentPasteLeavesTextUntouched() {
        let textView = DashboardComposerNativeTextView()
        textView.string = "Keep this draft"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/attachment fixture.pdf")
        board.writeObjects([file as NSURL])
        var attached: [URL] = []
        textView.onAttachFiles = { attached = $0; return true }
        expect(textView.attach(from: board), "File paste should use attachment callback")
        expect(attached == [file], "File URL should preserve spaces")
        expect(textView.string == "Keep this draft", "File paste must not replace the draft")
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.writeObjects([image])
        expect(textView.attach(from: board), "Screenshot paste should create an attachment")
        expect(attached.first?.pathExtension == "png", "Screenshot must be a real PNG")
        if let url = attached.first {
            expect(NSImage(contentsOf: url) != nil, "Staged screenshot should decode")
            DashboardComposerNativeTextView.releaseTemporaryAttachments([url])
            expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "Owned paste staging must be cleaned after attachment staging")
        }
        let unrelatedFolder = FileManager.default.temporaryDirectory.appending(path: "wovenmatter-paste-user-" + UUID().uuidString)
        let unrelatedFile = unrelatedFolder.appending(path: "report.txt")
        do {
            try FileManager.default.createDirectory(at: unrelatedFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: unrelatedFolder) }
            try Data("Keep this user file".utf8).write(to: unrelatedFile)
            DashboardComposerNativeTextView.releaseTemporaryAttachments([unrelatedFile])
            expect(FileManager.default.fileExists(atPath: unrelatedFile.path), "A matching folder name does not grant ownership of user files")
        } catch { fatalError("Could not prepare attachment cleanup fixture: \(error)") }
        var rejectedFile: URL?
        textView.onAttachFiles = { rejectedFile = $0.first; return false }
        expect(!textView.attach(from: board), "A rejected screenshot attachment must remain rejected")
        if let rejectedFile {
            expect(!FileManager.default.fileExists(atPath: rejectedFile.path), "Rejected paste staging must be cleaned immediately")
        } else { fatalError("Screenshot rejection must reach the attachment callback") }
        board.clearContents(); board.setString("ordinary text", forType: .string)
        expect(!textView.attach(from: board), "Text paste should remain native")
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

    private static func testPickerNavigationIsNarrowAndOptional() {
        let textView = DashboardComposerNativeTextView()
        var moves: [Int] = []
        var dismissals = 0
        textView.onMoveSelection = {
            moves.append($0)
            return true
        }
        textView.onEscape = {
            dismissals += 1
            return true
        }
        textView.keyDown(with: keyEvent(keyCode: 125, characters: "\u{F701}"))
        textView.keyDown(with: keyEvent(keyCode: 126, characters: "\u{F700}"))
        textView.keyDown(with: keyEvent(keyCode: 53, characters: "\u{1B}"))
        expect(moves == [1, -1], "plain arrows must navigate an active picker")
        expect(dismissals == 1, "Escape must dismiss an active picker")

        textView.keyDown(with: keyEvent(keyCode: 125, characters: "\u{F701}", modifiers: .shift))
        textView.keyDown(with: keyEvent(keyCode: 126, characters: "\u{F700}", modifiers: .command))
        expect(moves == [1, -1], "modified arrows must not navigate the picker")

        textView.setMarkedText(
            "候補",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.keyDown(with: keyEvent(keyCode: 125, characters: "\u{F701}"))
        expect(moves == [1, -1], "IME candidate navigation must not reach the picker")
    }

    private static func testCompletionMovesCaretWithoutChangingOrdinarySelection() {
        var editor = DashboardComposerTextEditor(
            text: .constant("/"),
            isFocused: .constant(true),
            placeholder: "Message…",
            maximumVisibleLines: 3,
            onSubmit: {},
            onTab: { false },
            onCommandNavigation: { _ in false }
        )
        let coordinator = editor.makeCoordinator()
        let textView = DashboardComposerNativeTextView()
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor = DashboardComposerTextEditor(
            text: .constant("/skill 🦞 "),
            isFocused: .constant(true),
            placeholder: "Message…",
            maximumVisibleLines: 3,
            onSubmit: {},
            onTab: { false },
            onCommandNavigation: { _ in false },
            completionRequest: .constant(1)
        )
        coordinator.parent = editor
        coordinator.reconcileText(for: textView)
        expect(textView.string == "/skill 🦞 ", "completion must apply the updated draft")
        expect(textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0), "completion must place the caret after the full UTF16 command")

        textView.setSelectedRange(NSRange(location: 1, length: 5))
        coordinator.reconcileText(for: textView)
        expect(textView.selectedRange() == NSRange(location: 1, length: 5), "ordinary updates must not replay completion or collapse a selection")

        editor.completionRequest = .constant(2)
        coordinator.parent = editor
        coordinator.reconcileText(for: textView)
        expect(textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0), "a new completion must move the caret even when the draft already matches")
    }

    private static func testTypingBeforeSwiftUIAppliesCompletion() {
        var draft = "/"
        var completion = 0
        let editor = DashboardComposerTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true), placeholder: "Message…", maximumVisibleLines: 3,
            onSubmit: {}, onTab: { false }, onCommandNavigation: { _ in false },
            completionRequest: Binding(get: { completion }, set: { completion = $0 })
        )
        let coordinator = editor.makeCoordinator()
        let textView = DashboardComposerNativeTextView()
        textView.delegate = coordinator
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.onPrepareInput = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.reconcilePendingCompletion(for: textView)
        }
        draft = "/command11 "
        completion += 1
        // The next key arrives before updateNSView refreshes coordinator.parent.
        textView.keyDown(with: keyEvent(keyCode: 0, characters: ""))
        expect(textView.string == "/command11 ", "a pending completion must settle before native input")
        // Deliver text separately, as NSTextInputClient does, so the fixture
        // does not depend on a window or the host keyboard input source.
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(textView.string == "/command11 a", "typing must first apply a pending command completion: \(textView.string.debugDescription)")
        expect(draft == "/command11 a", "the native edit must keep the bound draft current")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.reconcileText(for: textView)
        expect(textView.selectedRange().location == 2, "a later SwiftUI update must not apply the same caret move again")
    }

    private static func drainCaretReports() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !drained && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        expect(drained, "main queue must drain pending caret reports")
    }

    private static func testCaretReportsUseTheLatestNativeSelection() {
        var reports: [Bool] = []
        let editor = DashboardComposerTextEditor(
            text: .constant("/help 🦞"),
            isFocused: .constant(true),
            placeholder: "Message…",
            maximumVisibleLines: 3,
            onSubmit: {},
            onTab: { false },
            onCommandNavigation: { _ in false },
            onCaretAtEndChange: { reports.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        let textView = DashboardComposerNativeTextView()
        textView.delegate = coordinator
        textView.string = "/help 🦞"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.scheduleCaretReport(for: textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        expect(reports.isEmpty, "caret reports must not mutate SwiftUI state during an editor update")
        drainCaretReports()
        expect(reports == [true], "queued reports must observe the latest caret and discard stale earlier positions")

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        drainCaretReports()
        expect(reports == [true, false], "moving into the draft must hide end-of-draft completions")

        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        drainCaretReports()
        expect(reports == [true, false], "selecting text through the end is not an end caret and must not repeat the report")
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
