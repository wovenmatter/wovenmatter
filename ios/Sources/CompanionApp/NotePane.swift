import SwiftUI
import UIKit
import WebKit
import CompanionClient
import WovenMatterCompanion

struct EmptyNotePane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 18) {
      DashboardLucideIcon(glyph: .fileText, size: 44).foregroundStyle(DashboardPalette.mutedForeground)
      Text("Notes").font(.title2.bold())
      Button("New note") { Task { await model.newNote() } }.buttonStyle(DashboardPrimaryButtonStyle()).accessibilityIdentifier("action-new-note")
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct NotePane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  let note: CompanionNote
  @State private var title: String
  @State private var content: String
  @State private var editorBase: CompanionNote
  @State private var documentGeneration = 0
  @State private var selectedBlockID: String?
  @State private var conflictsPresented = false
  @State private var detailsPresented = false
  @State private var dictationEditor = MobileDictationEditor()
  @State private var editorController = MobileNoteEditorController()
  @State private var showsCharacterCount = false
  @State private var showsSaveDetails = false
  @State private var showsLinkEditor = false
  @State private var link = ""
  init(model: CompanionModel, note: CompanionNote) {
    self.model = model; self.note = note
    _title = State(initialValue: model.draftTitles[note.id] ?? note.title)
    _content = State(initialValue: model.draftContents[note.id] ?? note.content)
    _editorBase = State(initialValue: note)
    _conflictsPresented = State(initialValue: model.fixture && ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"] == "conflict")
  }
  private var document: NoteDocument? { RichDocumentEditing.document(content) }
  private var editable: Bool { RichDocumentEditing.canEdit(content) && !model.state.uncachedNoteIDs.contains(note.id) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        Button { editorController.undo() } label: {
          Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
        }.disabled(!editable || !editorController.canUndo).accessibilityLabel("Undo").accessibilityIdentifier("note-undo")
        Button { editorController.redo() } label: {
          Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44)
        }.disabled(!editable || !editorController.canRedo).accessibilityLabel("Redo").accessibilityIdentifier("note-redo")
        Spacer(minLength: 0)
        Menu {
          Menu("Heading and style") {
            Button("Body") { setStyle(.paragraph) }
            ForEach(1...6, id: \.self) { level in
              Button("Heading \(level)") { setStyle(NoteParagraphStyle.allCases[level]) }
            }
          }
          Button("Bulleted list", systemImage: "list.bullet") { setStyle(.bulletedList) }
          Button("Numbered list", systemImage: "list.number") { setStyle(.numberedList) }
          Divider()
          Button("Bold", systemImage: "bold") { format(.bold) }
          Button("Italic", systemImage: "italic") { format(.italic) }
          Button("Underline", systemImage: "underline") { format(.underline) }
          Menu("Highlight") {
            Button("Yellow") { format(.highlight("#FFF59D")) }
            Button("Green") { format(.highlight("#C8E6C9")) }
            Button("Pink") { format(.highlight("#F8BBD0")) }
            Button("Remove highlight") { format(.highlight(nil)) }
          }
          Button("Link", systemImage: "link") { showsLinkEditor = true }
          Button("Remove link") { format(.link(nil)) }
          Menu("Font") {
            ForEach(["System", "Helvetica Neue", "Avenir Next", "Georgia", "Menlo"], id: \.self) { family in
              Button(family) { format(.fontFamily(family == "System" ? nil : family)) }
            }
          }
          Menu("Font size") {
            ForEach([11, 12, 14, 16, 18, 21, 24, 30, 36], id: \.self) { size in
              Button("\(size) pt") { format(.fontSize(Double(size))) }
            }
          }
        } label: {
          Image(systemName: "textformat").font(.title3.weight(.medium)).frame(width: 44, height: 44)
        }.disabled(!editable).accessibilityLabel("Format note").accessibilityIdentifier("note-format")
        if editable, document?.kind == .note { MobileDictationMicrophone(editor: dictationEditor) }
        Menu {
          Button("Details, move and export") { detailsPresented = true }
            .disabled(!model.online && !model.canEditNoteDetails(note.id))
          Button("Reference in new chat", glyph: .messageSquare) { model.newChat(referencing: note.id) }.disabled(!editable)
          if model.state.conflicts[note.id] != nil { Button("Review saved conflict", systemImage: "doc.on.doc") { conflictsPresented = true } }
          ShareLink(item: content) { Label("Export original document", systemImage: "square.and.arrow.up") }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Note actions")
        Button { Task { await model.newNote() } } label: {
          DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44)
        }.accessibilityLabel("New note").accessibilityIdentifier("action-new-note")
      }.buttonStyle(DashboardIconButtonStyle()).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
      TextField("Untitled note", text: Binding(get: { title }, set: { title = $0; persist() }), axis: .vertical)
        .font(.title.weight(.semibold)).lineLimit(1...3)
        .accessibilityIdentifier("note-title").disabled(!editable)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
      if model.state.conflicts[note.id] != nil {
        Button { conflictsPresented = true } label: { Label("Review saved conflict", systemImage: "doc.on.doc").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(theme.palette.themeWhisper) }.padding(.horizontal, 20)
      }
      if model.state.uncachedNoteIDs.contains(note.id) {
        ContentUnavailableView("Not saved on this device", systemImage: "icloud.and.arrow.down", description: Text("Download this document from the central library."))
        if model.online { Button("Download document") { Task { await model.openNote(note.id) } }.buttonStyle(DashboardPrimaryButtonStyle()).padding() }
      } else if let document {
        if document.kind == .html {
          Text("HTML asset · read only").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
          if document.databaseLink != nil {
            LinkedArtifactPreview(model: model, note: note, tableID: nil, html: document.html)
          } else { SafeHTMLPreview(html: document.html) }
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if document.kind != .note { Text("Spreadsheet · read only").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
              else if !editable { Text("Read only · unsupported attributes preserved").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
              if document.kind == .spreadsheet, document.databaseLink != nil, document.blocks.isEmpty {
                LinkedArtifactPreview(model: model, note: note, tableID: nil, html: nil)
              }
              ForEach(document.blocks, id: \.id) { block in
                switch block {
                case .richText(let text):
                  HStack(alignment: .top, spacing: 9) {
                    RichBlockTextView(block: text, generation: documentGeneration, editable: editable, controller: editorController,
                      dictationEditor: dictationEditor, dictationIdentity: "note:\(note.id):\(text.id)",
                      focused: { selectedBlockID = text.id; MobileDictation.shared.activeEditor = dictationEditor }) { range, replacement in
                      do {
                        let next = try RichDocumentEditing.replacingText(in: content, blockID: text.id, range: range, replacement: replacement, attributes: editorController.typingRun)
                        editorController.expectCaret(NSRange(location: range.location + replacement.utf16.count, length: 0))
                        editorController.recordTextChange(from: content, to: next, blockID: text.id, apply: adopt)
                        content = next
                        documentGeneration += 1
                        persist()
                        guard let document = RichDocumentEditing.document(content), let new = document.blocks.first(where: { $0.id == text.id }), case .richText(let result) = new else { return nil }
                        return (result, documentGeneration)
                      } catch { model.errorMessage = error.localizedDescription; return nil }
                    }.accessibilityIdentifier("note-body-editor-\(text.id)")
                  }
                case .table(let table):
                  if table.databaseLink != nil || (document.kind == .spreadsheet && document.databaseLink != nil) {
                    LinkedArtifactPreview(model: model, note: note, tableID: table.databaseLink != nil ? table.id : nil, html: nil)
                  } else { NativeTablePreview(table: table) }
                }
              }
            }.padding(.horizontal, 20).padding(.bottom, 20)
          }.scrollDismissesKeyboard(.interactively)
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Label("Read only · original format preserved", systemImage: "lock.doc").font(.subheadline.weight(.medium))
            Text("This document uses a format this device cannot edit. Open it on your Mac or export the original document.").foregroundStyle(DashboardPalette.mutedForeground)
            Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }.padding(20)
        }
      }
      HStack(spacing: 8) {
        Button { showsSaveDetails.toggle() } label: {
          HStack(spacing: 4) {
            DashboardLucideIcon(glyph: model.state.conflicts[note.id] != nil ? .alertCircle : .check, size: 11)
            Text(model.compactSaveLabel(note.id))
          }.frame(minHeight: 28)
        }.accessibilityLabel(model.saveLabel(note.id)).accessibilityIdentifier("note-save-state")
          .popover(isPresented: $showsSaveDetails) {
            Text(model.saveLabel(note.id)).font(.callout).padding(16).presentationCompactAdaptation(.popover)
          }
        Spacer()
        if let document, document.kind == .note {
          let statistics = MobileNoteTextStatistics(document: document)
          Button { showsCharacterCount.toggle() } label: {
            Text(showsCharacterCount ? statistics.characterLabel : statistics.wordLabel).monospacedDigit().frame(minHeight: 28)
          }.accessibilityLabel(showsCharacterCount ? "Note character count" : "Note word count")
            .accessibilityValue(String(showsCharacterCount ? statistics.characters : statistics.words))
            .accessibilityHint(showsCharacterCount ? "Show word count" : "Show character count")
            .accessibilityIdentifier("note-text-count")
        }
      }.font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
        .buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 4)
    }
    .onChange(of: note) { _, new in
      if new == model.state.notes[note.id], model.draftContents[note.id] == nil && model.draftTitles[note.id] == nil {
        if content != new.content { documentGeneration += 1; editorController.reset() }
        content = new.content; title = new.title; editorBase = new
      }
    }
    .onDisappear { editorController.reset() }
    .alert("Link", isPresented: $showsLinkEditor) {
      TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
      Button("Apply") { format(.link(link.trimmingCharacters(in: .whitespacesAndNewlines))) }
      Button("Cancel", role: .cancel) { }
    } message: { Text("Apply a link to the selected text.") }
    .navigationDestination(isPresented: $detailsPresented) {
      ItemManagementSheet(model: model, id: note.id, isNote: true, title: title, folderID: note.folderID ?? "")
    }
    .navigationDestination(isPresented: $conflictsPresented) {
      if let conflict = model.state.conflicts[note.id] { ConflictPane(model: model, id: note.id, conflict: conflict) }
    }
  }
  private func persist() { if editable { model.saveNote(id: note.id, title: title, content: content, base: editorBase) } }
  private func setStyle(_ style: NoteParagraphStyle) {
    guard let id = selectedBlockID ?? document?.blocks.first?.id else { return }
    change { try RichDocumentEditing.settingStyle(in: content, blockID: id, style: style) }
  }
  private func format(_ format: RichDocumentEditing.TextFormat) {
    guard let id = editorController.activeBlockID ?? selectedBlockID ?? document?.blocks.first?.id else { return }
    if let selection = editorController.selection, selection.length == 0,
      let block = document?.blocks.first(where: { $0.id == id }), case .richText(let text) = block {
      var offset = 0
      let inherited = text.runs.first { run in
        defer { offset += run.text.utf16.count }
        return selection.location <= offset + run.text.utf16.count
      } ?? text.runs.last ?? NoteTextRun(text: "")
      var run = editorController.typingRun ?? inherited
      switch format {
      case .bold: run.bold.toggle()
      case .italic: run.italic.toggle()
      case .underline: run.underline.toggle()
      case .highlight(let hex): run.highlightHex = hex
      case .fontFamily(let family): run.fontFamily = family
      case .fontSize(let size): run.fontSize = size
      case .link(let url):
        if let url, !["https", "http", "mailto"].contains(URL(string: url)?.scheme?.lowercased() ?? "") {
          model.errorMessage = "Enter an http, https or mailto link."; return
        }
        run.link = url
      }
      editorController.setTypingRun(run)
    } else {
      editorController.clearTypingRun()
      change { try RichDocumentEditing.formattingText(in: content, blockID: id, range: editorController.selection, format: format) }
    }
  }
  private func adopt(_ value: String) { content = value; documentGeneration += 1; persist() }
  private func change(_ operation: () throws -> String) {
    do {
      let next = try operation()
      guard next != content else { return }
      editorController.recordChange(from: content, to: next, apply: adopt)
      adopt(next)
    } catch { model.errorMessage = error.localizedDescription }
  }
}

/// The document owns undo across text blocks and formatting. UIKit still owns
/// input, selection and composition, but must not register separate range-based
/// undo operations against text storage which SwiftUI can replace on restoration.
@MainActor @Observable final class MobileNoteEditorController {
  @ObservationIgnored let history = MobileNoteUndoManager()
  @ObservationIgnored private weak var activeView: UITextView?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var currentContent: String?
  @ObservationIgnored private(set) var typingRun: NoteTextRun?
  @ObservationIgnored private var expectedCaret: NSRange?
  @ObservationIgnored private var typingBlock: String?
  @ObservationIgnored private var lastTypedAt: ContinuousClock.Instant?
  private(set) var activeBlockID: String?
  private(set) var canUndo = false
  private(set) var canRedo = false
  var selection: NSRange? { activeView?.selectedRange }
  init() {
    history.levelsOfUndo = 100
    history.groupsByEvent = false
    history.disableUndoRegistration()
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
  func clearTypingRun() { typingRun = nil }
  func setTypingRun(_ run: NoteTextRun) {
    typingRun = run
    var sample = run; sample.text = " "
    activeView?.typingAttributes = RichBlockTextView.attributed(.init(runs: [sample])).attributes(at: 0, effectiveRange: nil)
  }
  func refreshUndoState() { canUndo = history.canUndo; canRedo = history.canRedo }
  func undo() { guard history.canUndo else { return }; history.undo(); refreshUndoState() }
  func redo() { guard history.canRedo else { return }; history.redo(); refreshUndoState() }
  func reset() { history.removeAllActions(); currentContent = nil; typingBlock = nil; lastTypedAt = nil; clearTypingRun(); refreshUndoState() }
  func recordTextChange(from old: String, to new: String, blockID: String, apply: @escaping (String) -> Void) {
    guard old != new else { return }
    let now = ContinuousClock.now
    let coalesces = typingBlock == blockID && lastTypedAt.map { $0.duration(to: now) < .milliseconds(650) } == true && !history.canRedo
    if !coalesces { registerRestoration(old, apply: apply, action: "Typing") }
    currentContent = new; typingBlock = blockID; lastTypedAt = now
    refreshUndoState()
  }
  func recordChange(from old: String, to new: String, apply: @escaping (String) -> Void) {
    registerRestoration(old, apply: apply, action: "Format note")
    currentContent = new; typingBlock = nil; lastTypedAt = nil
    refreshUndoState()
  }
  private func registerRestoration(_ value: String, apply: @escaping (String) -> Void, action: String) {
    let ownsGroup = !history.isUndoing && !history.isRedoing
    let wasDisabled = !history.isUndoRegistrationEnabled
    if wasDisabled { history.enableUndoRegistration() }
    if ownsGroup { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { controller in
      guard let inverse = controller.currentContent else { return }
      controller.registerRestoration(inverse, apply: apply, action: action)
      controller.currentContent = value
      apply(value)
    }
    history.setActionName(action)
    if ownsGroup { history.endUndoGrouping() }
    if wasDisabled { history.disableUndoRegistration() }
  }
}

/// Redo registration must be enabled before Foundation opens its inverse group.
/// Native input remains unregistered outside the document's restoration actions.
final class MobileNoteUndoManager: UndoManager {
  override func undo() {
    let wasDisabled = !isUndoRegistrationEnabled
    if wasDisabled { enableUndoRegistration() }
    super.undo()
    if wasDisabled { disableUndoRegistration() }
  }
  override func redo() {
    let wasDisabled = !isUndoRegistrationEnabled
    if wasDisabled { enableUndoRegistration() }
    super.redo()
    if wasDisabled { disableUndoRegistration() }
  }
}

final class MobileNoteTextView: UITextView {
  private let history: UndoManager
  init(history: UndoManager) { self.history = history; super.init(frame: .zero, textContainer: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var undoManager: UndoManager? { history }
}

private struct ConflictPane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  var id: String
  var conflict: MobileNoteConflict
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Group {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(conflict.reason).font(.subheadline)
          version("Your iPhone version", note: conflict.local)
          version("Mac version", note: conflict.remote)
          version("Common saved version", note: conflict.base)
          Button("Keep iPhone version as a new note") { Task { await model.preserveConflict(id); dismiss() } }.buttonStyle(DashboardPrimaryButtonStyle())
          Text("The Mac version keeps its original identity. Your writing becomes a new note, so a deleted note is never silently restored.").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        }.padding(20)
      }.navigationTitle("Saved conflict").navigationBarTitleDisplayMode(.inline)
        .mobilePageSurface().toolbar(.visible, for: .navigationBar)
    }.tint(theme.palette.themeAccent)
  }
  private func version(_ label: String, note: CompanionNote?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.headline)
      if let note { Text(note.title).font(.subheadline.bold()); Text(RichDocumentEditing.document(note.content)?.plainText ?? note.content).font(.subheadline).textSelection(.enabled); Text("Revision \(note.revision)").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
      else { Text("Deleted or not yet created on the Mac").foregroundStyle(DashboardPalette.mutedForeground) }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
  }
}

struct RichBlockTextView: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  var block: NoteRichTextBlock
  var generation: Int
  var editable: Bool
  var controller: MobileNoteEditorController
  var dictationEditor: MobileDictationEditor
  var dictationIdentity: String
  var focused: () -> Void
  var edit: (NSRange, String) -> (NoteRichTextBlock, Int)?
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = MobileNoteTextView(history: controller.history)
    view.isScrollEnabled = false; view.backgroundColor = .clear
    view.textContainerInset = .init(top: 6, left: 0, bottom: 6, right: 0); view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = true
    view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    view.tintColor = DashboardColors.primary
    view.linkTextAttributes = [.foregroundColor: DashboardColors.success]
    view.delegate = context.coordinator; view.attributedText = Self.attributed(block)
    dictationEditor.bind(view, identity: dictationIdentity)
    controller.bind(view, blockID: block.id)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    guard generation >= context.coordinator.latestGeneration else { return }
    context.coordinator.parent = self; view.isEditable = editable
    dictationEditor.bind(view, identity: dictationIdentity)
    context.coordinator.latestGeneration = generation
    if context.coordinator.renderedBlock != block {
      let desired = Self.attributed(block)
      let selection = view.selectedRange; view.attributedText = desired
      let start = min(selection.location, desired.length)
      view.selectedRange = NSRange(location: start, length: min(selection.length, desired.length - start))
      context.coordinator.renderedBlock = block
    }
    view.accessibilityLabel = block.plainText.isEmpty ? "Note paragraph" : nil
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: max(42, size.height))
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: RichBlockTextView
    var latestGeneration: Int
    var renderedBlock: NoteRichTextBlock
    init(_ parent: RichBlockTextView) { self.parent = parent; latestGeneration = parent.generation; renderedBlock = parent.block }
    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.dictationEditor.bind(textView, identity: parent.dictationIdentity)
      parent.controller.activate(textView, blockID: parent.block.id)
      parent.focused()
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      guard let (result, generation) = parent.edit(range, text) else { return false }
      latestGeneration = generation; renderedBlock = result
      let desired = RichBlockTextView.attributed(result)
      if !text.isEmpty, desired.length > 0 { textView.typingAttributes = desired.attributes(at: min(range.location, desired.length - 1), effectiveRange: nil) }
      // UIKit owns insertion, composition and selection. Replacing the
      // attributed string on every key races SwiftUI and resets keyboard state.
      return true
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
        if let (result, generation) = parent.edit(.init(location: start, length: length), replacement) {
          renderedBlock = result; latestGeneration = generation
        } else { textView.attributedText = RichBlockTextView.attributed(renderedBlock) }
      }
      textView.invalidateIntrinsicContentSize()
      parent.controller.refreshUndoState()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      if textView.isFirstResponder { parent.controller.activate(textView, blockID: parent.block.id) }
    }
  }
  static func attributed(_ block: NoteRichTextBlock) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
    if block.style == .bulletedList || block.style == .numberedList {
      paragraph.textLists = [NSTextList(markerFormat: block.style == .bulletedList ? .disc : .decimal, options: 0)]
      paragraph.headIndent = 24
    }
    for run in block.runs.isEmpty ? [NoteTextRun(text: "")] : block.runs {
      let size: CGFloat = switch block.style { case .heading1: 29; case .heading2: 24; case .heading3, .heading4, .heading5, .heading6: 20; default: 17 }
      var font = run.fontFamily.flatMap { UIFont(name: $0, size: CGFloat(run.fontSize ?? Double(size))) } ?? UIFont.systemFont(ofSize: CGFloat(run.fontSize ?? Double(size)))
      var traits = font.fontDescriptor.symbolicTraits
      if run.bold || block.style.rawValue.hasPrefix("heading") { traits.insert(.traitBold) }
      if run.italic { traits.insert(.traitItalic) }
      if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
      var attributes: [NSAttributedString.Key: Any] = [.font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font), .foregroundColor: UIColor(DashboardPalette.foreground), .paragraphStyle: paragraph]
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if let foreground = run.foregroundHex.flatMap(UIColor.init(hex:)) { attributes[.foregroundColor] = DashboardColors.noteForeground(foreground) }
      if let background = run.highlightHex.flatMap(UIColor.init(hex:)) { attributes[.backgroundColor] = DashboardColors.noteBackground(background) }
      if let value = run.link, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }
}

private struct NativeTablePreview: View {
  @Environment(\.dashboardTheme) private var theme
  let table: NoteTableBlock
  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
          GridRow {
            ForEach(row.cells) { cell in
              Text(AttributedString(RichBlockTextView.attributed(.init(runs: cell.runs))))
                .frame(minWidth: 100, minHeight: 34, alignment: .leading).padding(8)
                .background(cell.backgroundHex.flatMap(UIColor.init(hex:)).map { Color(dashboardColor: DashboardColors.noteBackground($0)) }
                  ?? (index < table.headerRowCount ? theme.palette.themeWhisper : .clear))
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)).textSelection(.enabled)
            }
          }
        }
      }
    }.accessibilityLabel("Table, read only")
  }
}

private extension UIColor {
  convenience init?(hex: String) {
    let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
    self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
  }
}

struct SafeHTMLPreview: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  let html: String
  var linkedDataJSON: String? = nil
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    return view
  }
  func updateUIView(_ view: WKWebView, context: Context) {
    // Only the app-owned empty canvas follows the theme. Authored documents
    // keep their exact HTML and are not reloaded when the theme changes.
    let emptyDark = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && colorScheme == .dark
    let body = emptyDark ? String(format: "<style>body{background:#%06X}</style>", DashboardColors.darkWorkspace) : html
    let rendered = MobileArtifactPreview.renderedHTML(html: body, linkedDataJSON: linkedDataJSON)
    guard context.coordinator.loaded != rendered else { return }
    context.coordinator.loaded = rendered
    view.loadHTMLString(rendered, baseURL: nil)
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded: String?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
  }
}

private struct LinkedArtifactPreview: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  let note: CompanionNote
  let tableID: String?
  let html: String?
  @State private var data: CompanionLinkedData?
  @State private var error: String?
  @State private var loading = false
  private var requestKey: String { "\(note.id):\(note.revision):\(tableID ?? "document"):\(model.online)" }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Live linked data · read only", glyph: .database).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        Spacer()
        if loading { ProgressView().controlSize(.small) }
        else { Button("Refresh") { Task { await load() } }.font(.caption).disabled(!model.online) }
      }.padding(.horizontal, html == nil ? 0 : 20)
      if let error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(.horizontal, html == nil ? 0 : 20) }
      if let html { SafeHTMLPreview(html: html, linkedDataJSON: data?.json) }
      else if let data {
        ScrollView(.horizontal) {
          LazyVStack(alignment: .leading, spacing: 0) {
            row(data.columns, header: true)
            ForEach(Array(data.rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
          }
        }.accessibilityLabel("Live linked table, read only")
      }
    }.task(id: requestKey) { await load() }
  }
  @ViewBuilder private func row(_ cells: [String], header: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(cells.enumerated()), id: \.offset) { _, text in
        Text(text).font(header ? .subheadline.bold() : .subheadline).textSelection(.enabled)
          .frame(width: 150, alignment: .leading).padding(8)
          .background(header ? theme.palette.themeWhisper : .clear)
          .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
      }
    }
  }
  private func load() async {
    let key = requestKey
    data = nil; error = nil; loading = true
    defer { if requestKey == key { loading = false } }
    guard model.online else { error = "Connect to your Mac to preview this linked data."; return }
    do {
      let result = try await model.linkedData(note: note, tableID: tableID)
      guard !Task.isCancelled, requestKey == key else { return }
      data = result
    } catch is CancellationError {} catch { if requestKey == key { self.error = error.localizedDescription } }
  }
}
