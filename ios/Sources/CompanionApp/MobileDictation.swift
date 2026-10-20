import SwiftUI
import UIKit
import WovenMatterCompanion

@MainActor @Observable final class MobileDictationEditor {
  @ObservationIgnored weak var textView: UITextView?
  @ObservationIgnored var identity = ""
  func bind(_ view: UITextView, identity: String) {
    guard textView == nil || textView === view || view.isFirstResponder else { return }
    textView = view; self.identity = identity
  }
  func ticket() -> MobileDictationTicket? {
    guard let view = textView, view.isEditable, view.markedTextRange == nil else { return nil }
    return .init(editor: self, identity: identity, insertion: .init(text: view.text ?? "", selection: view.selectedRange))
  }
}

@MainActor struct MobileDictationTicket {
  let editor: MobileDictationEditor
  let identity: String
  let insertion: DictationInsertion
  func insert(_ text: String) -> Bool {
    guard editor.identity == identity, let view = editor.textView, view.isEditable, view.markedTextRange == nil,
          let range = insertion.range(in: view.text ?? ""),
          let start = view.position(from: view.beginningOfDocument, offset: range.location),
          let end = view.position(from: start, offset: range.length),
          let target = view.textRange(from: start, to: end) else { return false }
    // UIKit owns replacement, typing attributes, delegate callbacks and undo.
    // Honor the existing rich-note edit admission hook before making the edit.
    guard view.delegate?.textView?(view, shouldChangeTextIn: range, replacementText: text) != false else { return false }
    view.undoManager?.beginUndoGrouping()
    view.replace(target, withText: text)
    view.undoManager?.setActionName("Dictation")
    view.undoManager?.endUndoGrouping()
    view.delegate?.textViewDidChange?(view)
    return true
  }
}

@MainActor final class MobileDictation {
  static let shared = MobileDictation()
  let session = DictationSession.shared
  weak var activeEditor: MobileDictationEditor?
  func toggle(_ editor: MobileDictationEditor) {
    activeEditor = editor
    if session.retainedTranscript != nil { session.insertRetained { editor.ticket()?.insert($0) == true }; return }
    if session.isRecording { stop(); return }
    guard editor.ticket() != nil else { session.error = "Place the cursor in an editable text input first."; return }
    session.start()
  }
  func stop() {
    let ticket = activeEditor?.ticket()
    session.stop { ticket?.insert($0) == true }
  }
}

struct MobileDictationMicrophone: View {
  var editor: MobileDictationEditor
  private var session: DictationSession { MobileDictation.shared.session }
  var body: some View {
    Button { MobileDictation.shared.toggle(editor) } label: {
      Image(systemName: session.isRecording ? "stop.circle.fill" : "mic")
        .font(.system(size: 20)).frame(width: 44, height: 44)
        .foregroundStyle(session.isRecording ? DashboardPalette.danger : DashboardPalette.foreground)
    }
    .buttonStyle(DashboardIconButtonStyle())
    .disabled(session.phase == .finishing || !session.enabled)
    .accessibilityLabel(session.retainedTranscript != nil ? "Insert retained dictation here" : session.isRecording ? "Stop recording and insert here" : "Start dictation")
    .accessibilityIdentifier("dictation-microphone")
    .contextMenu {
      Menu("Dictation language") {
        Button("Automatic") { session.languageIdentifier = "" }
        ForEach(session.availableLanguages, id: \.self) { language in
          Button(Locale.current.localizedString(forIdentifier: language) ?? language) { session.languageIdentifier = language }
        }
      }.disabled(session.isBusy)
    }
    .task { await session.loadLanguages() }
  }
}

struct MobileDictationFeedback: View {
  private var session: DictationSession { MobileDictation.shared.session }
  var body: some View {
    if session.isBusy || session.error != nil || session.retainedTranscript != nil {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(title).font(.subheadline.weight(.medium))
          Spacer()
          Button(session.isBusy ? "Cancel" : session.retainedTranscript != nil ? "Discard" : "Dismiss") { session.cancel() }
            .font(.subheadline).frame(minHeight: 44)
        }
        if !session.preview.isEmpty { Text(session.preview).font(.caption).lineLimit(3) }
        if let error = session.error { Text(error).font(.caption).foregroundStyle(DashboardPalette.danger) }
        if let retained = session.retainedTranscript { Text(retained).font(.caption).lineLimit(4).textSelection(.enabled) }
      }.padding(12).background(DashboardPalette.background, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
        .padding(12).accessibilityIdentifier("dictation-feedback")
    }
  }
  private var title: String {
    switch session.phase {
    case .idle: session.retainedTranscript == nil ? "Dictation" : "Transcript ready to insert"
    case .preparing: session.downloadProgress.map { "Preparing dictation language… \(Int($0 * 100))%" } ?? "Preparing on-device dictation…"
    case .recording: "Recording · Stop in a conversation or note to insert"
    case .finishing: "Finishing dictation…"
    }
  }
}

/// Native composer text view exposes a real caret for both keyboard dictation
/// and the app's microphone while preserving selection during SwiftUI updates.
struct MobileDictationComposer: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  var editor: MobileDictationEditor
  var identity: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.backgroundColor = .clear
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
    view.showsVerticalScrollIndicator = false; view.showsHorizontalScrollIndicator = false
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    let changedOwner = context.coordinator.parent.identity != identity
    context.coordinator.parent = self
    if view.text != text {
      let selection = view.selectedRange
      view.text = text
      view.selectedRange = changedOwner ? NSRange(location: text.utf16.count, length: 0) : NSRange(location: min(selection.location, text.utf16.count), length: min(selection.length, text.utf16.count - min(selection.location, text.utf16.count)))
    }
    if changedOwner { view.undoManager?.removeAllActions() }
    view.textColor = .label
    editor.bind(view, identity: identity)
    if focused && !view.isFirstResponder { view.becomeFirstResponder() }
    if !focused && view.isFirstResponder { view.resignFirstResponder() }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let line = uiView.font?.lineHeight ?? 22
    let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    return CGSize(width: width, height: min(max(line * 2, height), line * 6))
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: MobileDictationComposer
    init(_ parent: MobileDictationComposer) { self.parent = parent }
    func textViewDidChange(_ view: UITextView) { parent.text = view.text ?? ""; view.invalidateIntrinsicContentSize() }
    func textViewDidBeginEditing(_ view: UITextView) {
      parent.editor.bind(view, identity: parent.identity)
      MobileDictation.shared.activeEditor = parent.editor
      parent.focused = true
    }
    func textViewDidEndEditing(_ view: UITextView) { parent.focused = false }
  }
}
