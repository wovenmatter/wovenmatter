import SwiftUI
import UIKit
import WebKit
import CompanionClient
import WovenMatterCompanion

struct EmptyNotePane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "doc.text").font(.system(size: 44)).foregroundStyle(.secondary)
      Text("A place for your next idea").font(.title2.bold())
      Text("Create a note here or choose one in Folders. Your writing works offline.").foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button("New note") { Task { await model.newNote() } }.buttonStyle(.borderedProminent).foregroundStyle(.white)
    }.padding(30)
  }
}

struct NotePane: View {
  @Bindable var model: CompanionModel
  let note: CompanionNote
  @State private var title: String
  @State private var content: String
  @State private var editorBase: CompanionNote
  @State private var documentGeneration = 0
  @State private var selectedBlockID: String?
  @State private var conflictsPresented = false
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
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        TextField("Untitled note", text: Binding(get: { title }, set: { title = $0; persist() }), axis: .vertical).font(.title.bold()).lineLimit(1...3)
          .accessibilityIdentifier("note-title").disabled(!editable)
        Menu {
          Button("Paragraph") { setStyle(.paragraph) }
          Button("Heading") { setStyle(.heading2) }
          Button("Bullet list") { setStyle(.bulletedList) }
          Button("Bold paragraph") {
            guard let id = selectedBlockID ?? document?.blocks.first?.id else { return }
            change { try RichDocumentEditing.togglingBold(in: content, blockID: id) }
          }
          Button("Add paragraph", systemImage: "plus") { change { try RichDocumentEditing.appendingParagraph(to: content) } }
        } label: { Text("Aa").font(.title3.weight(.medium)).frame(width: 36, height: 44) }.disabled(!editable).accessibilityLabel("Note formatting")
        Menu {
          Button("Reference in new chat", systemImage: "bubble.left") { model.newChat(); model.referencedNoteID = note.id }.disabled(!editable)
          if model.state.conflicts[note.id] != nil { Button("Review saved conflict", systemImage: "doc.on.doc") { conflictsPresented = true } }
          ShareLink(item: content) { Label("Export original document", systemImage: "square.and.arrow.up") }
        } label: { Image(systemName: "ellipsis").frame(width: 30, height: 44) }.accessibilityLabel("Note actions")
      }.padding(.horizontal, 20).padding(.top, 14)
      HStack(spacing: 6) {
        Image(systemName: model.state.conflicts[note.id] != nil ? "exclamationmark.circle" : "checkmark")
        Text(model.saveLabel(note.id)).accessibilityIdentifier("note-save-state")
        Spacer()
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
      if model.state.conflicts[note.id] != nil {
        Button { conflictsPresented = true } label: { Label("Your writing is safe. Review the Mac version.", systemImage: "doc.on.doc").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(MobileTheme.surface) }.padding(.horizontal, 20)
      }
      if model.state.uncachedNoteIDs.contains(note.id) {
        ContentUnavailableView("Not saved on this iPhone", systemImage: "icloud.and.arrow.down", description: Text("Connect to your Mac to open the full document. Its title and folder are available offline."))
        if model.online { Button("Download document") { Task { await model.openNote(note.id) } }.buttonStyle(.borderedProminent).foregroundStyle(.white).padding() }
      } else if let document {
        if document.kind == .html {
          Text("HTML asset · read only").font(.caption).foregroundStyle(.secondary)
          if document.databaseLink != nil {
            LinkedArtifactPreview(model: model, note: note, tableID: nil, html: document.html)
          } else { SafeHTMLPreview(html: document.html) }
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if document.kind != .note { Text("Spreadsheet · read only").font(.caption).foregroundStyle(.secondary) }
              else if !editable { Text("Read only · unsupported attributes preserved").font(.caption).foregroundStyle(.secondary) }
              if document.kind == .spreadsheet, document.databaseLink != nil, document.blocks.isEmpty {
                LinkedArtifactPreview(model: model, note: note, tableID: nil, html: nil)
              }
              ForEach(document.blocks, id: \.id) { block in
                switch block {
                case .richText(let text):
                  HStack(alignment: .top, spacing: 9) {
                    if text.style == .bulletedList { Text("•").font(.body).padding(.top, 8) }
                    if text.style == .numberedList { Text("\((document.blocks.firstIndex(where: { $0.id == text.id }) ?? 0) + 1).").font(.body).padding(.top, 8) }
                    RichBlockTextView(block: text, generation: documentGeneration, editable: editable, focused: { selectedBlockID = text.id }) { range, replacement in
                      do {
                        content = try RichDocumentEditing.replacingText(in: content, blockID: text.id, range: range, replacement: replacement)
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
              if editable {
                Button { change { try RichDocumentEditing.appendingParagraph(to: content) } } label: { Label("Add paragraph", systemImage: "plus").font(.caption).foregroundStyle(.secondary) }.padding(.top, 12)
              }
            }.padding(.horizontal, 20).padding(.bottom, 50)
          }.scrollDismissesKeyboard(.interactively)
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Label("Read only · original format preserved", systemImage: "lock.doc").font(.subheadline.weight(.medium))
            Text("This document uses a format this iPhone cannot edit. Open it on your Mac or export the original document.").foregroundStyle(.secondary)
            Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }.padding(20)
        }
      }
      Spacer(minLength: 0)
    }
    .onChange(of: note) { _, new in
      if new == model.state.notes[note.id], model.draftContents[note.id] == nil && model.draftTitles[note.id] == nil {
        if content != new.content { documentGeneration += 1 }
        content = new.content; title = new.title; editorBase = new
      }
    }
    .sheet(isPresented: $conflictsPresented) {
      if let conflict = model.state.conflicts[note.id] { ConflictPane(model: model, id: note.id, conflict: conflict) }
    }
  }
  private func persist() { if editable { model.saveNote(id: note.id, title: title, content: content, base: editorBase) } }
  private func setStyle(_ style: NoteParagraphStyle) {
    guard let id = selectedBlockID ?? document?.blocks.first?.id else { return }
    change { try RichDocumentEditing.settingStyle(in: content, blockID: id, style: style) }
  }
  private func change(_ operation: () throws -> String) {
    do { content = try operation(); documentGeneration += 1; persist() } catch { model.errorMessage = error.localizedDescription }
  }
}

private struct ConflictPane: View {
  @Bindable var model: CompanionModel
  var id: String
  var conflict: MobileNoteConflict
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(conflict.reason).font(.subheadline)
          version("Your iPhone version", note: conflict.local)
          version("Mac version", note: conflict.remote)
          version("Common saved version", note: conflict.base)
          Button("Keep iPhone version as a new note") { Task { await model.preserveConflict(id); dismiss() } }.buttonStyle(.borderedProminent).foregroundStyle(.white)
          Text("The Mac version keeps its original identity. Your writing becomes a new note, so a deleted note is never silently restored.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
      }.navigationTitle("Saved conflict").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }.tint(MobileTheme.green)
  }
  private func version(_ label: String, note: CompanionNote?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.headline)
      if let note { Text(note.title).font(.subheadline.bold()); Text(RichDocumentEditing.document(note.content)?.plainText ?? note.content).font(.subheadline).textSelection(.enabled); Text("Revision \(note.revision)").font(.caption).foregroundStyle(.secondary) }
      else { Text("Deleted or not yet created on the Mac").foregroundStyle(.secondary) }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct RichBlockTextView: UIViewRepresentable {
  var block: NoteRichTextBlock
  var generation: Int
  var editable: Bool
  var focused: () -> Void
  var edit: (NSRange, String) -> (NoteRichTextBlock, Int)?
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isScrollEnabled = false; view.backgroundColor = .clear
    view.textContainerInset = .init(top: 6, left: 0, bottom: 6, right: 0); view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = true
    view.delegate = context.coordinator; view.attributedText = Self.attributed(block)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    guard generation >= context.coordinator.latestGeneration else { return }
    context.coordinator.parent = self; view.isEditable = editable
    context.coordinator.latestGeneration = generation
    if context.coordinator.renderedBlock != block {
      let desired = Self.attributed(block)
      let selection = view.selectedRange; view.attributedText = desired
      view.selectedRange = NSRange(location: min(selection.location, desired.length), length: 0)
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
    func textViewDidBeginEditing(_ textView: UITextView) { parent.focused() }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      guard let (result, generation) = parent.edit(range, text) else { return false }
      latestGeneration = generation; renderedBlock = result
      let desired = RichBlockTextView.attributed(result)
      if !text.isEmpty, desired.length > 0 { textView.typingAttributes = desired.attributes(at: min(range.location, desired.length - 1), effectiveRange: nil) }
      // UIKit owns insertion, composition, selection and undo. Replacing the
      // attributed string on every key races SwiftUI and resets keyboard state.
      return true
    }
    func textViewDidChange(_ textView: UITextView) {
      let actual = textView.text ?? ""
      if actual != renderedBlock.plainText {
        // Native undo/autocorrection may alter text outside shouldChangeTextIn.
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
    }
  }
  static func attributed(_ block: NoteRichTextBlock) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
    for run in block.runs.isEmpty ? [NoteTextRun(text: "")] : block.runs {
      let size: CGFloat = switch block.style { case .heading1: 29; case .heading2: 24; case .heading3, .heading4, .heading5, .heading6: 20; default: 17 }
      var font = run.fontFamily.flatMap { UIFont(name: $0, size: CGFloat(run.fontSize ?? Double(size))) } ?? UIFont.systemFont(ofSize: CGFloat(run.fontSize ?? Double(size)))
      var traits = font.fontDescriptor.symbolicTraits
      if run.bold || block.style.rawValue.hasPrefix("heading") { traits.insert(.traitBold) }
      if run.italic { traits.insert(.traitItalic) }
      if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
      var attributes: [NSAttributedString.Key: Any] = [.font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if let foreground = run.foregroundHex.flatMap(UIColor.init(hex:)) { attributes[.foregroundColor] = foreground }
      if let background = run.highlightHex.flatMap(UIColor.init(hex:)) { attributes[.backgroundColor] = background }
      if let value = run.link, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }
}

private struct NativeTablePreview: View {
  let table: NoteTableBlock
  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
          GridRow {
            ForEach(row.cells) { cell in
              Text(AttributedString(RichBlockTextView.attributed(.init(runs: cell.runs))))
                .frame(minWidth: 100, minHeight: 34, alignment: .leading).padding(8)
                .background(index < table.headerRowCount ? MobileTheme.surface : .clear)
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
    let rendered = MobileArtifactPreview.renderedHTML(html: html, linkedDataJSON: linkedDataJSON)
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
        Label("Live linked data · read only", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if loading { ProgressView().controlSize(.small) }
        else { Button("Refresh") { Task { await load() } }.font(.caption).disabled(!model.online) }
      }.padding(.horizontal, html == nil ? 0 : 20)
      if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, html == nil ? 0 : 20) }
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
          .background(header ? MobileTheme.surface : .clear)
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
