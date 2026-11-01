import XCTest
import UIKit
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
}
