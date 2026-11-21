import Foundation
import Observation
import WovenProtocol

/// The text of one open Note or Page: every edit made on this device, applied
/// to the document the shared `DocumentsStore` holds, which shows it at once
/// and saves it. The document owns undo; a change from elsewhere (another
/// machine, or an agent's tool) is shown as it lands and fences that history.
@MainActor @Observable final class ArtifactTextSession {
  let id: String
  let controller = MobileNoteEditorController()
  let dictation = MobileDictationEditor()
  /// Bumped on every document change, so a paragraph's view ignores a stale update.
  private(set) var generation = 0
  var selectedBlockID: String?
  /// The last edit that could not be made, until dismissed.
  var error: String?
  /// Identity of the empty paragraph offered after a final table until the user writes in it.
  let trailingParagraphID = UUID().uuidString.lowercased()
  /// Paragraph IDs offered at a Page's empty writing places.
  let placeholders = MobilePagePlaceholders()
  @ObservationIgnored private unowned let documents: DocumentsStore
  /// The document as this session last wrote or saw it.
  @ObservationIgnored private var known: String?

  init(id: String, documents: DocumentsStore) {
    self.id = id
    self.documents = documents
  }

  /// The document JSON, with this device's edits applied.
  var content: String { documents.notes[id]?.content ?? "" }
  var document: NoteDocument? { decoded.document }
  var isPage: Bool { document?.kind == .canvas }
  var editable: Bool { decoded.editable }
  /// The document as last decoded, reused until it changes: views read it many times per keystroke.
  @ObservationIgnored private var cache: (source: String, document: NoteDocument?, editable: Bool)?
  private var decoded: (document: NoteDocument?, editable: Bool) {
    let source = content
    if let cache, cache.source == source { return (cache.document, cache.editable) }
    let value = (RichDocumentEditing.document(source),
                 RichDocumentEditing.canEdit(source) || MobilePageEditing.canEdit(source))
    cache = (source, value.0, value.1)
    return value
  }

  /// Called whenever the store's document changes. A change this session did
  /// not make came from elsewhere: paragraphs show it, keeping the caret where
  /// it was, and undo no longer reaches across it.
  func observeStore() {
    let current = content
    guard current != known else { return }
    if known != nil {
      generation += 1
      controller.reset()
    }
    known = current
  }

  private func adopt(_ value: String) {
    known = value
    generation += 1
    documents.updateNote(id: id, content: value)
  }

  /// A typed edit inside one paragraph. Returns the paragraph as it now is.
  func edit(_ blockID: String, range: NSRange, replacement: String) -> (NoteRichTextBlock, Int)? {
    do {
      let before = content
      let (next, _) = try textEdit(blockID) { base in
        (try RichDocumentEditing.replacingText(in: base, blockID: blockID, range: range, replacement: replacement,
                                               attributes: controller.typingRun), ())
      }
      let after = RichDocumentEditing.Caret(blockID: blockID, location: range.location + replacement.utf16.count)
      controller.expectCaret(NSRange(location: after.location, length: 0))
      controller.recordTextChange(from: before, to: next, blockID: blockID,
                                  before: .init(blockID: blockID, location: NSMaxRange(range)), after: after,
                                  apply: { [weak self] in self?.adopt($0) })
      adopt(next)
      let blocks = isPage ? document?.materializedPage().blocks : document?.blocks
      guard let new = blocks?.first(where: { $0.id == blockID }), case .richText(let result) = new else { return nil }
      return (result, generation)
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  /// Runs a Notes text operation on the note, or on the Page flow holding `blockID`.
  /// A Page's paragraphs split from a task continue the task list.
  private func textEdit<T>(_ blockID: String, continuesTask: Bool = false,
                           _ operation: (String) throws -> (String, T)) throws -> (String, T) {
    guard isPage else { return try operation(try editableContent(blockID)) }
    var value: T?
    let next = try MobilePageEditing.commit(content) { page in
      guard let flow = MobilePageLayout(page: page, placeholders: placeholders).flow(containing: blockID) else {
        throw RichDocumentEditing.Failure.missingBlock
      }
      let isTask = page.boardItems?[blockID]?.task != nil
      let result = try MobilePageEditing.editFlow(&page, flow: flow, operation)
      value = result.value
      if continuesTask, isTask {
        for id in result.created { page.boardItems?[id] = BoardItem(task: BoardTask()) }
      }
    }
    guard let value else { throw RichDocumentEditing.Failure.missingBlock }
    return (next, value)
  }

  /// Applies one Page component change through the document's undo and save.
  /// Returns the refusal, if any.
  func pageChange(_ action: String, _ change: (inout NoteDocument) throws -> Void) -> String? {
    do {
      let before = content
      let next = try MobilePageEditing.commit(before, change: change)
      guard next != before else { return nil }
      controller.recordChange(from: before, to: next, action: action, apply: { [weak self] in self?.adopt($0) })
      adopt(next)
      return nil
    } catch {
      self.error = error.localizedDescription
      return error.localizedDescription
    }
  }

  private func isPageTask(_ blockID: String) -> Bool {
    isPage && document?.materializedPage().boardItems?[blockID]?.task != nil
  }

  /// A note that ends in a table, or has no blocks, offers an empty paragraph
  /// after it. It joins the document only once the user writes in it.
  func renderedBlocks(_ document: NoteDocument) -> [NoteBlock] {
    guard editable, document.kind == .note else { return document.blocks }
    if let last = document.blocks.last, case .richText = last { return document.blocks }
    return document.blocks + [.richText(.init(id: trailingParagraphID))]
  }

  private func isOfferedParagraph(_ blockID: String) -> Bool {
    blockID == trailingParagraphID && document?.blocks.contains { $0.id == blockID } == false
  }

  /// The content an edit to `blockID` applies to, including the offered paragraph once written in.
  private func editableContent(_ blockID: String) throws -> String {
    isOfferedParagraph(blockID) ? try RichDocumentEditing.appendingParagraph(to: content, id: blockID) : content
  }

  /// The paragraph formatting applies to: the one being edited, else the first.
  private var targetBlockID: String? {
    controller.activeBlockID ?? selectedBlockID ?? (isPage ? document?.materializedPage() : document)?.blocks.first?.id
  }

  func setStyle(_ style: NoteParagraphStyle) {
    guard let id = targetBlockID else { return }
    change { try textEdit(id) { (try RichDocumentEditing.settingStyle(in: $0, blockID: id, style: style), ()) }.0 }
  }

  func format(_ format: RichDocumentEditing.TextFormat) {
    guard let id = targetBlockID else { return }
    let blocks = isPage ? document?.materializedPage().blocks : document?.blocks
    if let selection = controller.selection, selection.length == 0,
       let block = blocks?.first(where: { $0.id == id }), case .richText(let text) = block {
      // With a caret, the format applies to what is typed next.
      var offset = 0
      let inherited = text.runs.first { run in
        defer { offset += run.text.utf16.count }
        return selection.location <= offset + run.text.utf16.count
      } ?? text.runs.last ?? NoteTextRun(text: "")
      var run = controller.typingRun ?? inherited
      switch format {
      case .bold: run.bold.toggle()
      case .italic: run.italic.toggle()
      case .underline: run.underline.toggle()
      case .highlight(let hex): run.highlightHex = hex
      case .fontFamily(let family): run.fontFamily = family
      case .fontSize(let size): run.fontSize = size
      case .link(let url):
        if let url, !["https", "http", "mailto"].contains(URL(string: url)?.scheme?.lowercased() ?? "") {
          error = "Enter an http, https or mailto link."
          return
        }
        run.link = url
      }
      controller.setTypingRun(run)
    } else {
      controller.clearTypingRun()
      let selection = controller.selection
      change { try textEdit(id) { (try RichDocumentEditing.formattingText(in: $0, blockID: id, range: selection, format: format), ()) }.0 }
    }
  }

  /// Return and multi-line paste create paragraphs; the caret follows into the new block.
  /// Returns whether the whole edit was saved, so dictation reports it exactly once.
  func editParagraphs(_ blockID: String, range: NSRange, replacement: String) -> Bool {
    do {
      // Return on an empty task returns to ordinary text, as on a Mac.
      if isPageTask(blockID), range.length == 0, RichDocumentEditing.containsParagraphBreak(replacement),
         replacement.trimmingCharacters(in: .newlines).isEmpty,
         document?.materializedPage().blocks.first(where: { $0.id == blockID })?.plainText.isEmpty == true {
        let next = try MobilePageEditing.commit(content) { $0.boardItems?[blockID]?.task = nil }
        return applyStructure(next, before: .init(blockID: blockID, location: 0), caret: .init(blockID: blockID, location: 0),
                              typingRun: nil, action: "End task list")
      }
      let typingRun = controller.typingRun
      let (next, (caret, typing)) = try textEdit(blockID, continuesTask: true) { base in
        let typing = typingRun ?? RichDocumentEditing.typingFormat(in: base, blockID: blockID, at: range.location)
        let result = try RichDocumentEditing.editing(base, blockID: blockID, range: range, replacement: replacement, attributes: typingRun)
        return (result.content, (result.caret, typing))
      }
      return applyStructure(next, before: .init(blockID: blockID, location: NSMaxRange(range)), caret: caret,
                            typingRun: caret.blockID == blockID ? nil : typing, action: "New paragraph")
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func mergeBackward(_ blockID: String) {
    guard !isOfferedParagraph(blockID) else { return }
    do {
      // Delete at the start of a task first returns it to ordinary text, like a list item.
      if isPageTask(blockID) {
        let next = try MobilePageEditing.commit(content) { $0.boardItems?[blockID]?.task = nil }
        applyStructure(next, before: .init(blockID: blockID, location: 0), caret: .init(blockID: blockID, location: 0),
                       typingRun: nil, action: "End task list")
        return
      }
      let (next, caret) = try textEdit(blockID) { base in
        guard let result = try RichDocumentEditing.mergingBackward(base, blockID: blockID) else {
          return (base, Optional<RichDocumentEditing.Caret>.none)
        }
        return (result.content, result.caret)
      }
      guard let caret else { return }
      applyStructure(next, before: .init(blockID: blockID, location: 0), caret: caret, typingRun: nil, action: "Delete")
    } catch {
      self.error = error.localizedDescription
    }
  }

  @discardableResult
  private func applyStructure(_ next: String, before: RichDocumentEditing.Caret, caret: RichDocumentEditing.Caret,
                              typingRun: NoteTextRun?, action: String) -> Bool {
    let current = content
    guard next != current else { return false }
    controller.recordChange(from: current, to: next, action: action, before: before, after: caret,
                            apply: { [weak self] in self?.adopt($0) })
    controller.focus(caret, typingRun: typingRun)
    selectedBlockID = caret.blockID
    adopt(next)
    return true
  }

  private func change(_ operation: () throws -> String) {
    do {
      let current = content
      let next = try operation()
      guard next != current else { return }
      controller.recordChange(from: current, to: next, apply: { [weak self] in self?.adopt($0) })
      adopt(next)
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Puts the caret at the end of the document's last paragraph, for dictation
  /// or formatting started before any text has the cursor.
  func focusEnd() {
    guard let document else { return }
    let blocks = isPage ? document.materializedPage().blocks : renderedBlocks(document)
    guard let last = blocks.last(where: { if case .richText = $0 { true } else { false } }),
          case .richText(let text) = last else { return }
    controller.focus(.init(blockID: text.id, location: text.plainText.utf16.count), typingRun: nil)
  }
}
