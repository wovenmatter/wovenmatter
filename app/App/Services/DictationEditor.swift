import AppKit
import Observation
#if canImport(WovenMatterCore)
import WovenMatterCore
#endif

/// Each native editor owns this small bridge. A ticket pins both the editor's
/// logical identity and its selection when Stop is clicked, not at Start.
@MainActor @Observable
final class DictationEditor {
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var identity = ""
    func bind(_ textView: NSTextView, identity: String) {
        self.textView = textView; self.identity = identity
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
        // insertText uses the native text system, preserving rich-text typing
        // attributes and emitting the existing delegate/binding callbacks.
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.insertText(text, replacementRange: range)
        view.undoManager?.setActionName("Dictation")
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        return true
    }
}
