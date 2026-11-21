import SwiftUI
import UIKit
import WovenProtocol

/// The document owns undo across text blocks and formatting. UIKit still owns
/// input, selection and composition, but must not register separate range-based
/// undo operations against text storage which SwiftUI can replace on restoration.
@MainActor @Observable final class MobileNoteEditorController {
  @ObservationIgnored let history = MobileNoteUndoManager()
  @ObservationIgnored private weak var activeView: UITextView?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var currentContent: String?
  @ObservationIgnored private var currentCaret: RichDocumentEditing.Caret?
  @ObservationIgnored private var restoresFocus = false
  @ObservationIgnored private(set) var typingRun: NoteTextRun?
  @ObservationIgnored private var expectedCaret: NSRange?
  @ObservationIgnored private var typingBlock: String?
  @ObservationIgnored private var lastTypedAt: ContinuousClock.Instant?
  @ObservationIgnored private var pendingFocus: (caret: RichDocumentEditing.Caret, typingRun: NoteTextRun?, raisesKeyboard: Bool, request: Int)?
  @ObservationIgnored private var focusRequests = 0
  private(set) var activeBlockID: String?
  private(set) var canUndo = false
  private(set) var canRedo = false
  /// A caret waiting for its block to render is already the selection, so
  /// formatting right after undo or Return addresses the block the user sees.
  var selection: NSRange? { pendingFocus.map { NSRange(location: $0.caret.location, length: 0) } ?? activeView?.selectedRange }
  init() {
    history.levelsOfUndo = 100
    history.groupsByEvent = false
    history.disableUndoRegistration()
    // Hardware keys, shake and the edit menu call the text view's undo manager
    // directly; they restore the caret exactly like the toolbar buttons.
    history.restoring = { [weak self] operation in
      guard let self else { operation(); return }
      self.restoring(operation)
    }
    for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: history, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.typingBlock = nil; self?.lastTypedAt = nil; self?.clearTypingRun()
          self?.refreshUndoState()
        }
      })
    }
  }
  isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
  func bind(_ view: UITextView, blockID: String) {
    if activeView == nil { activeView = view; activeBlockID = blockID }
  }
  func activate(_ view: UITextView, blockID: String) {
    if activeBlockID != blockID || expectedCaret.map({ $0 != view.selectedRange }) == true {
      typingBlock = nil; clearTypingRun()
    }
    activeView = view; activeBlockID = blockID
    expectedCaret = view.selectedRange
  }
  func expectCaret(_ range: NSRange) { expectedCaret = range }
  /// A structural edit names the block and offset where typing continues once that block renders.
  func focus(_ caret: RichDocumentEditing.Caret, typingRun: NoteTextRun?, raisesKeyboard: Bool = true) {
    focusRequests += 1
    pendingFocus = (caret, typingRun, raisesKeyboard, focusRequests); activeBlockID = caret.blockID
  }
  func claimFocus(_ view: UITextView, blockID: String) {
    // A view not yet in a window retries from didMoveToWindow.
    guard let pending = pendingFocus, pending.caret.blockID == blockID, view.window != nil else { return }
    // Defer focus changes out of SwiftUI's update pass.
    DispatchQueue.main.async { [weak self, weak view] in
      self?.completeFocus(view, blockID: blockID, request: pending.request, retries: 60)
    }
  }
  /// iOS 27 keeps a removed paragraph's view in the window, hidden, and can
  /// show it again for a recreated paragraph only after updating it. A hidden
  /// view either refuses the keyboard, dropping the caret, or takes it out of
  /// sight, so the caret waits until the view is shown.
  private func completeFocus(_ view: UITextView?, blockID: String, request: Int, retries: Int) {
    guard let view, view.window != nil, let pending = pendingFocus, pending.request == request, pending.caret.blockID == blockID else { return }
    guard Self.isShown(view) else {
      if retries > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self, weak view] in
          self?.completeFocus(view, blockID: blockID, request: request, retries: retries - 1)
        }
      }
      return
    }
    pendingFocus = nil
    if pending.raisesKeyboard, !view.isFirstResponder { view.becomeFirstResponder() }
    view.selectedRange = NSRange(location: min(pending.caret.location, view.attributedText.length), length: 0)
    activate(view, blockID: blockID)
    if let run = pending.typingRun { setTypingRun(run) }
  }
  static func isShown(_ view: UIView) -> Bool {
    var current: UIView? = view
    while let ancestor = current {
      if ancestor.isHidden || ancestor.alpha < 0.01 { return false }
      current = ancestor.superview
    }
    return view.window != nil
  }
  func clearTypingRun() { typingRun = nil }
  func setTypingRun(_ run: NoteTextRun) {
    typingRun = run
    var sample = run; sample.text = " "
    activeView?.typingAttributes = RichBlockTextView.attributed(.init(runs: [sample])).attributes(at: 0, effectiveRange: nil)
  }
  func refreshUndoState() { canUndo = history.canUndo; canRedo = history.canRedo }
  func undo() { guard history.canUndo else { return }; history.undo() }
  func redo() { guard history.canRedo else { return }; history.redo() }
  /// Undo can remove the focused paragraph. Editing continues at the restored
  /// caret; the keyboard is only raised again if it was already up.
  private func restoring(_ operation: () -> Void) {
    restoresFocus = activeView?.isFirstResponder == true
    operation()
    restoresFocus = false
    refreshUndoState()
  }
  func reset() { history.removeAllActions(); currentContent = nil; currentCaret = nil; pendingFocus = nil; typingBlock = nil; lastTypedAt = nil; clearTypingRun(); refreshUndoState() }
  /// `before` and `after` are where the caret stood around the change; undo and redo return there.
  func recordTextChange(from old: String, to new: String, blockID: String,
                        before: RichDocumentEditing.Caret, after: RichDocumentEditing.Caret, apply: @escaping (String) -> Void) {
    guard old != new else { return }
    let now = ContinuousClock.now
    let coalesces = typingBlock == blockID && lastTypedAt.map { $0.duration(to: now) < .milliseconds(650) } == true && !history.canRedo
    if !coalesces { registerRestoration(old, caret: before, apply: apply, action: "Typing") }
    currentContent = new; currentCaret = after; typingBlock = blockID; lastTypedAt = now
    refreshUndoState()
  }
  /// A change without carets, such as formatting, leaves the caret where it is.
  func recordChange(from old: String, to new: String, action: String = "Format note",
                    before: RichDocumentEditing.Caret? = nil, after: RichDocumentEditing.Caret? = nil, apply: @escaping (String) -> Void) {
    registerRestoration(old, caret: before, apply: apply, action: action)
    currentContent = new; typingBlock = nil; lastTypedAt = nil
    if let after { currentCaret = after }
    refreshUndoState()
  }
  private func registerRestoration(_ value: String, caret: RichDocumentEditing.Caret?, apply: @escaping (String) -> Void, action: String) {
    let ownsGroup = !history.isUndoing && !history.isRedoing
    let wasDisabled = !history.isUndoRegistrationEnabled
    if wasDisabled { history.enableUndoRegistration() }
    if ownsGroup { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { controller in
      guard let inverse = controller.currentContent else { return }
      controller.registerRestoration(inverse, caret: controller.currentCaret, apply: apply, action: action)
      controller.currentContent = value
      if let caret {
        controller.currentCaret = caret
        controller.typingBlock = nil; controller.clearTypingRun()
        controller.focus(caret, typingRun: nil, raisesKeyboard: controller.restoresFocus)
      }
      apply(value)
    }
    history.setActionName(action)
    if ownsGroup { history.endUndoGrouping() }
    if wasDisabled { history.disableUndoRegistration() }
  }
}

/// Redo registration must be enabled before Foundation opens its inverse group.
/// Native input remains unregistered outside the document's restoration actions.
/// Every undo and redo, from the toolbar or from UIKit, runs inside `restoring`.
final class MobileNoteUndoManager: UndoManager {
  var restoring: ((() -> Void) -> Void)?
  override func undo() { perform { super.undo() } }
  override func redo() { perform { super.redo() } }
  private func perform(_ operation: () -> Void) {
    let wasDisabled = !isUndoRegistrationEnabled
    if wasDisabled { enableUndoRegistration() }
    if let restoring { restoring(operation) } else { operation() }
    if wasDisabled { disableUndoRegistration() }
  }
}

final class MobileNoteTextView: UITextView {
  private let history: UndoManager
  /// Delete with the caret at the start of a paragraph joins it to the previous one.
  var deleteAtStart: (() -> Void)?
  var movedToWindow: (() -> Void)?
  init(history: UndoManager) { self.history = history; super.init(frame: .zero, textContainer: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var undoManager: UndoManager? { history }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { movedToWindow?() }
  }
  override func deleteBackward() {
    if markedTextRange == nil, selectedRange == NSRange(location: 0, length: 0), let deleteAtStart { deleteAtStart(); return }
    super.deleteBackward()
  }
}

struct RichBlockTextView: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  var block: NoteRichTextBlock
  /// The item number shown for a numbered-list paragraph.
  var listNumber: Int?
  var generation: Int
  var editable: Bool
  var controller: MobileNoteEditorController
  var dictationEditor: MobileDictationEditor
  var dictationIdentity: String
  var focused: () -> Void
  /// Applies a line break as a paragraph edit; false if nothing was saved.
  var paragraphBreak: (NSRange, String) -> Bool
  var deleteAtStart: () -> Void
  var edit: (NSRange, String) -> (NoteRichTextBlock, Int)?
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = MobileNoteTextView(history: controller.history)
    view.isScrollEnabled = false; view.backgroundColor = .clear
    view.textContainerInset = .init(top: 3, left: 0, bottom: 7, right: 0); view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = true
    view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    view.tintColor = WovenColors.primary
    view.linkTextAttributes = [.foregroundColor: WovenColors.success]
    view.delegate = context.coordinator; view.attributedText = Self.attributed(block, listNumber: listNumber)
    view.isEditable = editable
    dictationEditor.bind(view, identity: dictationIdentity)
    controller.bind(view, blockID: block.id)
    view.deleteAtStart = { [weak coordinator = context.coordinator] in coordinator?.parent.deleteAtStart() }
    view.movedToWindow = { [weak view, weak coordinator = context.coordinator] in
      guard let view, let coordinator else { return }
      coordinator.parent.controller.claimFocus(view, blockID: coordinator.parent.block.id)
    }
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    controller.claimFocus(view, blockID: block.id)
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    guard generation >= context.coordinator.latestGeneration else { return }
    context.coordinator.parent = self; view.isEditable = editable
    dictationEditor.bind(view, identity: dictationIdentity)
    context.coordinator.latestGeneration = generation
    if context.coordinator.renderedBlock != block || context.coordinator.renderedNumber != listNumber {
      let desired = Self.attributed(block, listNumber: listNumber)
      let selection = view.selectedRange; view.attributedText = desired
      let start = min(selection.location, desired.length)
      view.selectedRange = NSRange(location: start, length: min(selection.length, desired.length - start))
      context.coordinator.renderedBlock = block; context.coordinator.renderedNumber = listNumber
    }
    view.accessibilityLabel = block.plainText.isEmpty ? "Note paragraph" : nil
    controller.claimFocus(view, blockID: block.id)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: size.height)
  }
  final class Coordinator: NSObject, UITextViewDelegate, MobileTextAdmitting {
    var parent: RichBlockTextView
    var latestGeneration: Int
    var renderedBlock: NoteRichTextBlock
    var renderedNumber: Int?
    init(_ parent: RichBlockTextView) {
      self.parent = parent; latestGeneration = parent.generation; renderedBlock = parent.block; renderedNumber = parent.listNumber
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.dictationEditor.bind(textView, identity: parent.dictationIdentity)
      parent.controller.activate(textView, blockID: parent.block.id)
      parent.focused()
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      admit(textView, range: range, text: text) == .insertNatively
    }
    func admit(_ textView: UITextView, range: NSRange, text: String) -> MobileTextAdmission {
      // A paragraph break is a document change, never a newline inside this block.
      // The text view must not also insert it.
      if RichDocumentEditing.containsParagraphBreak(text) { return parent.paragraphBreak(range, text) ? .applied : .rejected }
      guard let (result, generation) = parent.edit(range, text) else { return .rejected }
      latestGeneration = generation; renderedBlock = result
      let desired = RichBlockTextView.attributed(result, listNumber: parent.listNumber)
      if !text.isEmpty, desired.length > 0 { textView.typingAttributes = desired.attributes(at: min(range.location, desired.length - 1), effectiveRange: nil) }
      // UIKit owns insertion, composition and selection. Replacing the
      // attributed string on every key races SwiftUI and resets keyboard state.
      return .insertNatively
    }
    func textViewDidChange(_ textView: UITextView) {
      let actual = textView.text ?? ""
      if actual != renderedBlock.plainText {
        // Autocorrection may alter text outside shouldChangeTextIn.
        // Reconcile the smallest character-aligned edit without flattening runs.
        let old = Array(renderedBlock.plainText), new = Array(actual)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix), old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let start = String(old.prefix(prefix)).utf16.count
        let length = String(old[prefix..<(old.count - suffix)]).utf16.count
        let replacement = String(new[prefix..<(new.count - suffix)])
        if RichDocumentEditing.containsParagraphBreak(replacement) {
          textView.attributedText = RichBlockTextView.attributed(renderedBlock, listNumber: renderedNumber)
          _ = parent.paragraphBreak(.init(location: start, length: length), replacement)
        } else if let (result, generation) = parent.edit(.init(location: start, length: length), replacement) {
          renderedBlock = result; latestGeneration = generation
        } else { textView.attributedText = RichBlockTextView.attributed(renderedBlock, listNumber: renderedNumber) }
      }
      textView.invalidateIntrinsicContentSize()
      parent.controller.refreshUndoState()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      if textView.isFirstResponder { parent.controller.activate(textView, blockID: parent.block.id) }
    }
  }
  /// A document's point sizes are the Mac's; the phone draws them larger by
  /// the ratio of its body text to the Mac's, so text written on either keeps
  /// its proportions on both.
  static let phoneScale = 17.0 / 14.0
  private static let fontFamilies = Set(UIFont.familyNames)

  /// The Mac's size for a style, when a run names none.
  static func documentSize(_ style: NoteParagraphStyle) -> Double {
    switch style {
    case .heading1: 30
    case .heading2: 25
    case .heading3: 21
    case .heading4: 18
    case .heading5: 16
    case .heading6, .paragraph, .bulletedList, .numberedList: 14
    }
  }

  /// Each paragraph is its own text view, so a numbered item carries its
  /// number in the list's starting value instead of counting siblings.
  static func attributed(_ block: NoteRichTextBlock, listNumber: Int? = nil) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
    if block.style == .bulletedList || block.style == .numberedList {
      let saved = block.list?.levels.last?.markerFormat.trimmingCharacters(in: .whitespaces)
      let marker = saved.flatMap { $0.isEmpty ? nil : NSTextList.MarkerFormat(rawValue: $0) }
        ?? (block.style == .bulletedList ? .disc : NSTextList.MarkerFormat(rawValue: "{decimal}."))
      paragraph.textLists = [NSTextList(markerFormat: marker, options: [], startingItemNumber: listNumber ?? 1)]
      paragraph.headIndent = 24
    }
    for run in block.runs.isEmpty ? [NoteTextRun(text: "")] : block.runs {
      let size = CGFloat((run.fontSize ?? documentSize(block.style)) * phoneScale)
      // A family this device lacks, such as the Mac's private system font name, is the system font.
      let family = run.fontFamily.flatMap { fontFamilies.contains($0) ? $0 : nil }
      var font = family.map { UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: $0]), size: size) }
        ?? UIFont.systemFont(ofSize: size)
      var traits = font.fontDescriptor.symbolicTraits
      if run.bold || block.style.rawValue.hasPrefix("heading") { traits.insert(.traitBold) }
      if run.italic { traits.insert(.traitItalic) }
      if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
      var attributes: [NSAttributedString.Key: Any] = [.font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font), .foregroundColor: WovenColors.noteForeground(), .paragraphStyle: paragraph]
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if let foreground = run.foregroundHex.flatMap(UIColor.init(hex:)) { attributes[.foregroundColor] = WovenColors.noteForeground(foreground) }
      if let background = run.highlightHex.flatMap(UIColor.init(hex:)) { attributes[.backgroundColor] = WovenColors.noteBackground(background) }
      if let value = run.link, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }
}

/// A note's table as the phone shows it: read only, scrolling sideways.
struct NativeTablePreview: View {
  @Environment(\.wovenTheme) private var theme
  let table: NoteTableBlock
  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
          GridRow {
            ForEach(row.cells) { cell in
              Text(AttributedString(RichBlockTextView.attributed(.init(runs: cell.runs))))
                .frame(minWidth: 100, minHeight: 34, alignment: .leading).padding(8)
                .background(cell.backgroundHex.flatMap(UIColor.init(hex:)).map { Color(wovenColor: WovenColors.noteBackground($0)) }
                  ?? (index < table.headerRowCount ? theme.palette.themeWhisper : .clear))
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)).textSelection(.enabled)
            }
          }
        }
      }
    }.accessibilityLabel("Table, read only")
  }
}

extension UIColor {
  /// A document's `#RRGGBB` colour.
  convenience init?(hex: String) {
    let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
    self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
  }
}
