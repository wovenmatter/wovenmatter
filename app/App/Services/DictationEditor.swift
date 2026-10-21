import AppKit
import Observation
#if canImport(WovenMatterCore)
import WovenMatterCore
#endif

/// Each native editor owns this small bridge. A ticket pins both the editor's
/// logical identity and its selection when Stop is clicked, not at Start.
@MainActor @Observable
final class DictationEditor {
    private static let editors = NSMapTable<NSTextView, DictationEditor>.weakToWeakObjects()
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var identity = ""
    func bind(_ textView: NSTextView, identity: String) {
        if let previous = self.textView, previous !== textView,
           Self.editors.object(forKey: previous) === self {
            Self.editors.removeObject(forKey: previous)
        }
        self.textView = textView; self.identity = identity
        Self.editors.setObject(self, forKey: textView)
    }
    static func focused(in window: NSWindow?) -> DictationEditor? {
        guard let textView = window?.firstResponder as? NSTextView,
              let editor = editors.object(forKey: textView), editor.textView === textView else { return nil }
        return editor
    }
    func ticket() -> DictationEditorTicket? {
        guard let textView, textView.isEditable, !textView.hasMarkedText() else { return nil }
        return .init(editor: self, identity: identity,
                     insertion: .init(text: textView.string, selection: textView.selectedRange()))
    }
}

@MainActor
struct DictationEditorTicket {
    let editor: DictationEditor
    let identity: String
    let insertion: DictationInsertion
    func insert(_ text: String) -> Bool {
        guard editor.identity == identity, let view = editor.textView,
              view.isEditable, !view.hasMarkedText(),
              let range = insertion.range(in: view.string) else { return false }
        let expected = (view.string as NSString).replacingCharacters(in: range, with: text)
        // insertText uses the native text system, preserving rich-text typing
        // attributes and emitting the existing delegate/binding callbacks.
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.insertText(text, replacementRange: range)
        view.undoManager?.setActionName("Dictation")
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        return view.string == expected
    }
}
