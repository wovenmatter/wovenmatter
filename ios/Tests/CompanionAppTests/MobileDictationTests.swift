import XCTest
import UIKit
import SwiftUI
import WovenMatterCompanion
import CompanionClient
@testable import WovenMatterMobileApp

@MainActor final class MobileDictationTests: XCTestCase {
  final class Delegate: NSObject, UITextViewDelegate {
    var admitsEdit = true
    var edits = 0
    var changes = 0
    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      edits += 1
      return admitsEdit
    }
    func textViewDidChange(_ view: UITextView) { changes += 1 }
  }

  func testNativeCaretReplacementPreservesAttributesAndNotifiesEditing() throws {
    let view = UITextView()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.rootViewController?.view.addSubview(view)
    view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
    window.makeKeyAndVisible()
    view.becomeFirstResponder()
    defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
    let delegate = Delegate(); view.delegate = delegate
    view.attributedText = NSAttributedString(string: "Before old after", attributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.red])
    view.selectedRange = NSRange(location: 7, length: 3)
    view.typingAttributes = [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.red]
    let history = try XCTUnwrap(view.undoManager)
    history.removeAllActions()
    let editor = MobileDictationEditor(); editor.bind(view, identity: "note:A:block:B")
    let ticket = try XCTUnwrap(editor.ticket())
    XCTAssertTrue(ticket.insert("new words"))
    XCTAssertEqual(view.text, "Before new words after")
    XCTAssertEqual((view.attributedText.attribute(.font, at: 8, effectiveRange: nil) as? UIFont)?.pointSize, 22)
    XCTAssertEqual(delegate.edits, 1, "Note edit admission must run once")
    XCTAssertGreaterThanOrEqual(delegate.changes, 1, "Bindings and note persistence must be notified")
    history.undo()
    XCTAssertEqual(view.text, "Before old after", "Dictation is one native undoable edit")
  }

  func testNoteUndoHistoryCoalescesTypingAcrossBlocksAndKeepsFormatting() throws {
    let controller = MobileNoteEditorController()
    var applied = "First edited\nSecond edited"
    let apply: (String) -> Void = { applied = $0 }
    func caret(_ block: String, _ location: Int) -> RichDocumentEditing.Caret { .init(blockID: block, location: location) }
    controller.recordTextChange(from: "First\nSecond", to: "First e\nSecond", blockID: "first", before: caret("first", 5), after: caret("first", 7), apply: apply)
    controller.recordTextChange(from: "First e\nSecond", to: "First edited\nSecond", blockID: "first", before: caret("first", 7), after: caret("first", 12), apply: apply)
    controller.recordTextChange(from: "First edited\nSecond", to: applied, blockID: "second", before: caret("second", 6), after: caret("second", 13), apply: apply)
    XCTAssertTrue(controller.canUndo)
    controller.undo(); XCTAssertEqual(applied, "First edited\nSecond")
    controller.undo(); XCTAssertEqual(applied, "First\nSecond")
    XCTAssertFalse(controller.canUndo)
    controller.redo(); XCTAssertEqual(applied, "First edited\nSecond")
    controller.redo(); XCTAssertEqual(applied, "First edited\nSecond edited")
    let document = try NoteDocument(blocks: [.richText(.init(text: applied))]).encoded()
    controller.recordChange(from: applied, to: document, apply: apply)
    controller.undo(); XCTAssertEqual(applied, "First edited\nSecond edited")
    controller.redo(); XCTAssertEqual(applied, document)
    controller.reset(); XCTAssertFalse(controller.canUndo); XCTAssertFalse(controller.canRedo)
  }

  func testChangedOwnerOrOverlappingEditRejectsLateResult() throws {
    let view = UITextView(); view.text = "Original"; view.selectedRange = NSRange(location: 3, length: 0)
    let editor = MobileDictationEditor(); editor.bind(view, identity: "chat:A")
    let ticket = try XCTUnwrap(editor.ticket())
    editor.identity = "chat:B"
    XCTAssertFalse(ticket.insert("obsolete"))
    editor.identity = "chat:A"; view.text = "Different"
    XCTAssertFalse(ticket.insert("obsolete"))
    XCTAssertEqual(view.text, "Different")
  }

  func testNativeNoteAdmissionCanRejectWithoutChangingText() throws {
    let view = UITextView(); view.text = "Preserve"; view.selectedRange = NSRange(location: 0, length: 0)
    let delegate = Delegate(); delegate.admitsEdit = false; view.delegate = delegate
    let editor = MobileDictationEditor(); editor.bind(view, identity: "note:A")
    XCTAssertFalse(try XCTUnwrap(editor.ticket()).insert("No"))
    XCTAssertEqual(view.text, "Preserve")
  }

  @MainActor private final class FinalizingEngine: DictationEngine {
    let (stream, continuation) = AsyncThrowingStream<DictationSegment, any Error>.makeStream()
    func prepare(languages: [Locale], progress: @escaping @MainActor (Double?) -> Void) async {}
    func start() async -> AsyncThrowingStream<DictationSegment, any Error> { stream }
    func stopCapture() {}
    func finish() async { continuation.finish() }
    func cancel() async { continuation.finish() }
  }

  /// A spoken line break becomes a new note paragraph. The structural edit is
  /// saved once, the text view does not also insert it, and dictation reports
  /// success, so no transcript is retained for a second, duplicate insertion.
  func testMultilineDictationIntoNoteParagraphSavesOnceAndRetainsNothing() async throws {
    let controller = MobileNoteEditorController()
    let editor = MobileDictationEditor()
    var breaks: [(NSRange, String)] = [], edits = 0
    let block = NoteRichTextBlock(id: "block", text: "Start")
    let representable = RichBlockTextView(block: block, listNumber: nil, generation: 0, editable: true, controller: controller,
      dictationEditor: editor, dictationIdentity: "note:A:block", focused: {},
      paragraphBreak: { range, text in breaks.append((range, text)); return true },
      deleteAtStart: {}) { _, _ in edits += 1; return nil }
    let coordinator = RichBlockTextView.Coordinator(representable)
    let view = MobileNoteTextView(history: controller.history)
    view.delegate = coordinator; view.text = "Start"; view.selectedRange = NSRange(location: 5, length: 0)
    editor.bind(view, identity: "note:A:block")
    let ticket = try XCTUnwrap(editor.ticket())

    let engine = FinalizingEngine()
    let session = DictationSession(preferences: UserDefaults(suiteName: "dictation-\(UUID())")!, permission: { true }, makeEngine: { engine })
    session.start()
    for _ in 0..<500 where session.phase != .recording { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(session.phase, .recording)
    engine.continuation.yield(.init(start: 0, end: 1, text: " first line\nsecond line", isFinal: true))
    for _ in 0..<500 where session.preview.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    session.stop { ticket.insert($0) }
    for _ in 0..<500 where session.phase != .idle { try await Task.sleep(for: .milliseconds(2)) }

    XCTAssertEqual(session.phase, .idle)
    XCTAssertEqual(breaks.count, 1, "The paragraph edit is applied exactly once")
    XCTAssertEqual(breaks.first?.0, NSRange(location: 5, length: 0))
    XCTAssertEqual(breaks.first?.1, "first line\nsecond line")
    XCTAssertEqual(edits, 0, "The structural edit is not also applied as in-paragraph typing")
    XCTAssertEqual(view.text, "Start", "The text view does not insert the break itself")
    XCTAssertNil(session.retainedTranscript, "Handled insertion leaves nothing to insert again")
    XCTAssertNil(session.error)

    // A structural edit that saves nothing is reported as not inserted.
    let refusing = RichBlockTextView(block: block, listNumber: nil, generation: 0, editable: true, controller: controller,
      dictationEditor: editor, dictationIdentity: "note:A:block", focused: {},
      paragraphBreak: { _, _ in false }, deleteAtStart: {}) { _, _ in nil }
    let refusingCoordinator = RichBlockTextView.Coordinator(refusing)
    view.delegate = refusingCoordinator
    XCTAssertFalse(try XCTUnwrap(editor.ticket()).insert("one\ntwo"))
    XCTAssertEqual(view.text, "Start")
  }

  /// Undoing Return removes the paragraph that had the caret. The caret,
  /// formatting target and selection return to the restored paragraph, and redo
  /// returns them to the new one, with no tap needed before typing or formatting.
  func testStructuralUndoAndRedoRestoreTheEditingCaret() throws {
    let controller = MobileNoteEditorController()
    var applied = "one paragraph"
    let apply: (String) -> Void = { applied = $0 }
    let split = RichDocumentEditing.Caret(blockID: "B", location: 0)
    controller.recordChange(from: "one paragraph", to: "two paragraphs", action: "New paragraph",
                            before: .init(blockID: "A", location: 3), after: split, apply: apply)
    controller.focus(split, typingRun: nil)
    XCTAssertEqual(controller.activeBlockID, "B")

    controller.undo()
    XCTAssertEqual(applied, "one paragraph")
    XCTAssertEqual(controller.activeBlockID, "A", "Formatting addresses the restored paragraph, not the removed one")
    XCTAssertEqual(controller.selection, NSRange(location: 3, length: 0))

    controller.redo()
    XCTAssertEqual(applied, "two paragraphs")
    XCTAssertEqual(controller.activeBlockID, "B")
    XCTAssertEqual(controller.selection, NSRange(location: 0, length: 0))

    // Formatting has no caret of its own; undoing it leaves the caret alone.
    controller.recordChange(from: "two paragraphs", to: "two bold paragraphs", apply: apply)
    controller.undo()
    XCTAssertEqual(applied, "two paragraphs")
    XCTAssertEqual(controller.activeBlockID, "B")
    controller.undo()
    XCTAssertEqual(controller.activeBlockID, "A")
  }

  /// A live note editor in a key window, driven through the same text view
  /// delegate and undo manager UIKit uses for keys, shake and the edit menu.
  @MainActor private struct LiveNote {
    let window: UIWindow, previous: UIWindow?, model: CompanionModel
    /// Every note text view in the window, including views iOS 27 keeps hidden
    /// for reuse after their paragraph is removed.
    func allEditors() -> [MobileNoteTextView] {
      func collect(_ view: UIView) -> [MobileNoteTextView] { (view as? MobileNoteTextView).map { [$0] } ?? view.subviews.flatMap(collect) }
      return collect(window)
    }
    /// The paragraphs on screen, top to bottom.
    func editors() -> [MobileNoteTextView] {
      allEditors().filter(MobileNoteEditorController.isShown)
        .sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }
    func describe() -> String {
      editors().map { "\($0.text ?? "")\($0.isFirstResponder ? " (keyboard)" : "")" }.joined(separator: " | ")
    }
    func content() -> String { model.draftContents[model.selectedNoteID ?? ""] ?? model.selectedNote?.content ?? "" }
    func close() { window.isHidden = true; previous?.makeKeyAndVisible() }
  }
  private func openNote() async throws -> LiveNote {
    let model = CompanionModel()
    await model.newNote()
    let note = try XCTUnwrap(model.selectedNote)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: NavigationStack { NotePane(model: model, note: note) })
    window.makeKeyAndVisible()
    return LiveNote(window: window, previous: previous, model: model)
  }
  private func settle(_ note: LiveNote? = nil, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The editor did not settle: \(note?.describe() ?? "")", line: line)
  }
  /// Types as the keyboard does: the delegate admits the edit, then UIKit inserts it unless the editor applied it.
  private func type(_ text: String, into view: UITextView) {
    view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
    if view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: text) != false { view.insertText(text) }
  }

  func testNativeUndoAndRedoOfReturnKeepTheKeyboardInTheRestoredParagraph() async throws {
    let note = try await openNote(); defer { note.close() }
    try await settle { note.editors().count == 1 }
    let first = try XCTUnwrap(note.editors().first)
    XCTAssertTrue(first.becomeFirstResponder())
    type("Plan", into: first)
    type("\n", into: first)
    try await settle(note) { note.editors().count == 2 && note.editors()[1].isFirstResponder }
    let second = note.editors()[1]
    XCTAssertTrue(second.undoManager === first.undoManager, "Every paragraph shares the note's history")

    // UIKit's own path: the focused text view's undo manager, not the toolbar.
    second.undoManager?.undo()
    try await settle(note) { note.editors().count == 1 && note.editors()[0].isFirstResponder }
    XCTAssertEqual(note.editors()[0].text, "Plan")
    XCTAssertEqual(note.allEditors().filter(\.isFirstResponder), [note.editors()[0]], "No hidden leftover holds the keyboard")

    note.editors()[0].undoManager?.redo()
    try await settle(note) { note.editors().count == 2 && note.editors()[1].isFirstResponder }
    type("Details", into: note.editors()[1])
    XCTAssertEqual(note.editors().map(\.text), ["Plan", "Details"], "Typing continues after redo without a tap")

    note.editors()[1].undoManager?.undo() // typing
    note.editors()[1].undoManager?.undo() // Return
    try await settle(note) { note.editors().count == 1 && note.editors()[0].isFirstResponder }
    type("!", into: note.editors()[0])
    XCTAssertEqual(note.editors()[0].text, "Plan!", "Typing continues after undo at the restored caret")
  }

  /// iOS 27 keeps a removed paragraph's view hidden in the window and shows
  /// it again when redo recreates the paragraph, after SwiftUI has updated it.
  /// The caret waits for the view to be shown instead of being dropped.
  func testCaretWaitsForAHiddenReusedParagraphToBeShown() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true; previous?.makeKeyAndVisible() }
    window.rootViewController = UIViewController()
    let controller = MobileNoteEditorController()
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 50)), view = MobileNoteTextView(history: controller.history)
    view.frame = host.bounds; view.text = "Restored"
    host.addSubview(view); window.rootViewController?.view.addSubview(host)
    window.makeKeyAndVisible()
    host.isHidden = true; host.alpha = 0

    controller.focus(.init(blockID: "B", location: 3), typingRun: nil)
    controller.claimFocus(view, blockID: "B")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(view.isFirstResponder, "A hidden paragraph does not take the keyboard out of sight")
    XCTAssertEqual(controller.selection, NSRange(location: 3, length: 0), "The caret is still waiting")

    host.isHidden = false; host.alpha = 1
    for _ in 0..<300 where !view.isFirstResponder { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(view.isFirstResponder, "Editing continues once the paragraph is shown")
    XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
    XCTAssertEqual(controller.activeBlockID, "B")
    view.resignFirstResponder()
  }

  /// One undo reverses one dictation, whether it inserted text in place or
  /// became new paragraphs, through the note editor's own undo manager.
  func testOneUndoReversesSingleAndMultilineDictation() async throws {
    let note = try await openNote(); defer { note.close() }
    try await settle { note.editors().count == 1 }
    let first = try XCTUnwrap(note.editors().first)
    XCTAssertTrue(first.becomeFirstResponder())
    type("Start", into: first)
    try await Task.sleep(for: .milliseconds(700)) // End typing coalescence.
    let typed = note.content()
    let editor = MobileDictationEditor(); editor.bind(first, identity: "note:dictation")

    XCTAssertTrue(try XCTUnwrap(editor.ticket()).insert(" spoken"))
    try await settle { note.editors().first?.text == "Start spoken" }
    first.undoManager?.undo()
    try await settle { note.editors().first?.text == "Start" }
    XCTAssertEqual(note.content(), typed, "One undo removes the whole single-line dictation")

    XCTAssertTrue(try XCTUnwrap(editor.ticket()).insert(" one\ntwo"))
    try await settle { note.editors().count == 2 }
    XCTAssertEqual(note.editors().map(\.text), ["Start one", "two"])
    note.editors()[1].undoManager?.undo()
    try await settle { note.editors().count == 1 }
    XCTAssertEqual(note.editors().first?.text, "Start")
    XCTAssertEqual(note.content(), typed, "One undo removes the whole multiline dictation")
  }

  /// Taps on note editing controls keep the keyboard; taps anywhere else still dismiss it.
  func testOnlyMarkedEditingControlsKeepTheKeyboard() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true; previous?.makeKeyAndVisible() }
    window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
      HStack { Button("Undo") {}; Button("Redo") {} }.frame(maxWidth: .infinity, minHeight: 44).keepsKeyboard()
      Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.background(MobileKeyboardDismissal()))
    window.makeKeyAndVisible()
    for _ in 0..<300 where MobileKeyboardDismissal.keepers.allObjects.first(where: { $0.window === window }) == nil { try await Task.sleep(for: .milliseconds(10)) }
    let keeper = try XCTUnwrap(MobileKeyboardDismissal.keepers.allObjects.first { $0.window === window })
    let toolbar = keeper.convert(keeper.bounds, to: window)
    XCTAssertGreaterThan(toolbar.height, 0)
    XCTAssertTrue(MobileKeyboardDismissal.keepsKeyboard(at: CGPoint(x: toolbar.midX, y: toolbar.midY), in: window))
    XCTAssertFalse(MobileKeyboardDismissal.keepsKeyboard(at: CGPoint(x: toolbar.midX, y: toolbar.maxY + 100), in: window), "Ordinary outside taps still dismiss")
    window.isHidden = true; window.rootViewController = nil
    for _ in 0..<300 where keeper.window != nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(MobileKeyboardDismissal.keepers.allObjects.contains { $0 === keeper }, "A removed control stops keeping the keyboard")
  }
}
