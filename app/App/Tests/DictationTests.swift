@testable import WovenMatterAppFacade
import AppKit
import Foundation
import Testing
import WovenMatterCompanion

@MainActor private final class SpeechFixture: DictationEngine {
    let stream: AsyncThrowingStream<DictationSegment, any Error>
    let continuation: AsyncThrowingStream<DictationSegment, any Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func prepare(languages: [Locale], progress: @escaping @MainActor (Double?) -> Void) async {}
    func start() async -> AsyncThrowingStream<DictationSegment, any Error> { stream }
    func stopCapture() {}
    func finish() async { continuation.finish() }
    func cancel() async { continuation.finish() }
}
@MainActor private final class UndoEditor: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}
@MainActor private final class RejectingDictationDelegate: NSObject, NSTextViewDelegate {
    var admissions = 0
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        admissions += 1
        return false
    }
}
@MainActor @Suite(.serialized) struct DictationTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Dictation did not settle")
    }
    private func editor(_ text: String, id: String, selection: NSRange) -> (DictationEditor, UndoEditor) {
        _ = NSApplication.shared
        let view = UndoEditor()
        view.string = text; view.allowsUndo = true; view.setSelectedRange(selection)
        let editor = DictationEditor(); editor.bind(view, identity: id)
        return (editor, view)
    }
    private func fixture(focusedWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) -> (DictationModel, SpeechFixture) {
        let speech = SpeechFixture()
        let session = DictationSession(preferences: UserDefaults(suiteName: "native-dictation-test-\(UUID())")!,
            permission: { true }, makeEngine: { speech })
        return (DictationModel(session: session, focusedWindow: focusedWindow), speech)
    }
    @Test func shortcutUsesTheCurrentWindowResponderAndIgnoresStaleEditors() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        var focusedWindow: NSWindow? = window
        let (model, speech) = fixture(focusedWindow: { focusedWindow })
        let (a, viewA) = editor("First", id: "A", selection: NSRange(location: 5, length: 0))
        let (b, viewB) = editor("Second ", id: "B", selection: NSRange(location: 7, length: 0))
        let search = NSTextView()
        window.contentView?.addSubview(viewA)
        window.contentView?.addSubview(search)
        secondWindow.contentView?.addSubview(viewB)
        #expect(window.makeFirstResponder(viewA))
        model.activeEditor = a
        model.refreshShortcutEditor()
        #expect(model.shortcutEditor === a)

        #expect(window.makeFirstResponder(search))
        model.refreshShortcutEditor()
        #expect(model.shortcutEditor == nil)
        model.toggleActiveEditor()
        #expect(model.phase == .idle, "A title, search field, or sheet must not start dictation in the old editor")

        focusedWindow = nil
        model.refreshShortcutEditor()
        #expect(model.shortcutEditor == nil)
        model.toggleActiveEditor()
        #expect(model.phase == .idle)

        focusedWindow = secondWindow
        #expect(secondWindow.makeFirstResponder(viewB))
        model.refreshShortcutEditor()
        #expect(model.activeEditor === a, "The cached editor deliberately belongs to the other window")
        #expect(model.shortcutEditor === b)
        model.toggleActiveEditor()
        try await settle { model.phase == .recording }
        speech.continuation.yield(.init(start: 0, end: 1, text: "dictated", isFinal: true))
        try await settle { model.preview == "dictated" }
        focusedWindow = window
        model.toggleActiveEditor()
        #expect(model.phase == .recording, "An unfocused editor must not receive a stop/insert shortcut")
        focusedWindow = secondWindow
        model.toggleActiveEditor()
        try await settle { model.phase == .idle }
        #expect(viewA.string == "First")
        #expect(viewB.string == "Second dictated")
        model.cancel()
    }
}
