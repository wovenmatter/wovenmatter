import XCTest
import UIKit
import WovenMatterCompanion
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
    let delegate = Delegate(); view.delegate = delegate
    view.attributedText = NSAttributedString(string: "Before old after", attributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.red])
    view.selectedRange = NSRange(location: 7, length: 3)
    view.typingAttributes = [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.red]
    let editor = MobileDictationEditor(); editor.bind(view, identity: "note:A:block:B")
    let ticket = try XCTUnwrap(editor.ticket())
    XCTAssertTrue(ticket.insert("new words"))
    XCTAssertEqual(view.text, "Before new words after")
    XCTAssertEqual((view.attributedText.attribute(.font, at: 8, effectiveRange: nil) as? UIFont)?.pointSize, 22)
    XCTAssertEqual(delegate.edits, 1, "Note edit admission must run once")
    XCTAssertGreaterThanOrEqual(delegate.changes, 1, "Bindings and note persistence must be notified")
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
}
