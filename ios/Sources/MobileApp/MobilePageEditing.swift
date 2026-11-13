import Foundation
import LibraryClient
import WovenMatterShared

/// Page editing on iPhone and iPad. Every rule lives in shared Page code; this
/// only projects the Page into rows the phone shows and runs the Notes text
/// editor on one flow of contiguous text at a time, as the Mac does.
enum MobilePageEditing {
  enum Failure: LocalizedError {
    case tooLarge
    var errorDescription: String? {
      switch self {
      case .tooLarge: "This change would make the Page larger than every device can still edit. The change was not made."
      }
    }
  }

  /// A Page this device can edit: saved here, structurally valid, with no linked data.
  static func canEdit(_ content: String) -> Bool {
    guard RichDocumentEditing.document(content) != nil,
          let document = try? NoteDocument.editableDocument(from: content), document.kind == .canvas,
          document.databaseLink == nil else { return false }
    return !document.blocks.contains { block in
      if case .table(let table) = block { return table.databaseLink != nil }
      return false
    }
  }

  /// Starts from the current document, applies the change, stamps the user's
  /// change and enforces the size every participant can still edit. An edit that
  /// changes nothing leaves the stored text untouched, so opening never converts.
  static func commit(_ content: String, change: (inout NoteDocument) throws -> Void) throws -> String {
    let before = try NoteDocument.editableDocument(from: content).materializedPage()
    guard before.kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    var value = before
    try change(&value)
    guard value != before else { return content }
    value.stampBoardChanges(from: before, actor: BoardActor(kind: .user))
    try value.validateEditableShape()
    let encoded = try value.encoded()
    guard encoded.utf8.count <= NoteDocument.maximumBoardBytes else { throw Failure.tooLarge }
    return encoded
  }

  /// Runs a Notes text operation on one flow, then splices the result back into
  /// the Page. Returns the operation's value and the IDs of paragraphs it created.
  static func editFlow<T>(_ page: inout NoteDocument, flow: MobilePageFlow,
                          _ operation: (String) throws -> (String, T)) throws -> (value: T, created: [String]) {
    var note = page.pageFlowDocument(blockIDs: flow.blockIDs)
    if flow.blockIDs.isEmpty, let placeholder = flow.placeholderID { note.blocks = [.richText(.init(id: placeholder))] }
    let (next, value) = try operation(try note.encoded())
    guard let edited = RichDocumentEditing.document(next) else { throw RichDocumentEditing.Failure.unsupported }
    let previous = Set(flow.blockIDs)
    try page.spliceFlow(flow.blockIDs, with: edited.blocks, parentID: flow.parentID, afterID: flow.afterID)
    return (value, edited.blocks.map(\.id).filter { !previous.contains($0) && $0 != flow.placeholderID })
  }

  /// Where a new component goes: after the selected component, inside a selected
  /// section, at a selected empty writing place, or at the end of the Page.
  static func insertionPosition(after selectedID: String?, in layout: MobilePageLayout) -> PagePosition {
    guard let id = selectedID else { return .init() }
    let page = layout.page
    if page.blocks.contains(where: { $0.id == id }) {
      return page.pageComponentKind(for: id) == .section ? .init(parentID: id) : .init(parentID: page.pageParentID(for: id), afterID: id)
    }
    if let flow = layout.flow(containing: id) {
      return .init(parentID: flow.parentID, afterID: flow.afterID, atStart: flow.afterID == nil)
    }
    return .init()
  }

  /// A sibling-relative move, as the Mac's Move up and Move down.
  static func siblingMove(_ id: String, by direction: Int, in page: NoteDocument) -> PagePosition? {
    let parent = page.pageParentID(for: id)
    let siblings = page.pageChildren(of: parent)
    guard let index = siblings.firstIndex(of: id) else { return nil }
    let destination = index + direction
    guard siblings.indices.contains(destination) else { return nil }
    if direction < 0 {
      return .init(parentID: parent, afterID: destination > 0 ? siblings[destination - 1] : nil, atStart: destination == 0)
    }
    return .init(parentID: parent, afterID: siblings[destination])
  }

  /// The nearest earlier sibling that is a section, which "Move into section above" targets.
  static func sectionAbove(_ id: String, in page: NoteDocument) -> String? {
    let siblings = page.pageChildren(of: page.pageParentID(for: id))
    guard let index = siblings.firstIndex(of: id) else { return nil }
    return siblings[..<index].last { page.pageNodes?[$0]?.isSection == true }
  }
}

/// A contiguous run of text, tasks and tables, which the Notes text editor edits as one note.
struct MobilePageFlow: Equatable {
  var id: String
  var parentID: String?
  var afterID: String?
  var depth: Int
  var blockIDs: [String]
  /// The paragraph offered in an empty flow. It joins the Page once written in.
  var placeholderID: String?
}

/// One line of the phone's Page layout, in reading order.
struct MobilePageRow: Identifiable, Equatable {
  enum Kind: Equatable { case text(placeholder: Bool), table, section, asset(String) }
  var id: String
  var kind: Kind
  var parentID: String?
  var depth: Int
  var flowID: String?
}

/// Empty writing places keep one paragraph ID per place, so typing the first
/// character keeps the same text view, keyboard and caret.
@MainActor final class MobilePagePlaceholders {
  private var ids: [String: String] = [:]
  func id(for flowID: String, in page: NoteDocument) -> String {
    // Asked only for an empty place, so an ID already on the Page was written elsewhere.
    if let id = ids[flowID], !page.blocks.contains(where: { $0.id == id }) { return id }
    let id = UUID().uuidString.lowercased()
    ids[flowID] = id
    return id
  }
}

struct MobilePageLayout {
  let page: NoteDocument
  let blocks: [String: NoteBlock]
  let rows: [MobilePageRow]
  let flows: [String: MobilePageFlow]
  private let flowOfRow: [String: String]
  let listNumbers: [String: Int]

  @MainActor init(page source: NoteDocument, placeholders: MobilePagePlaceholders) {
    let page = source.materializedPage()
    self.page = page
    blocks = Dictionary(page.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rows: [MobilePageRow] = [], flows: [String: MobilePageFlow] = [:], flowOfRow: [String: String] = [:]
    var numbers: [String: Int] = [:]
    for segment in Self.editorSegments(page) {
      switch segment {
      case let .flow(id, parentID, afterID, depth, blockIDs):
        var flow = MobilePageFlow(id: id, parentID: parentID, afterID: afterID, depth: depth, blockIDs: blockIDs)
        if blockIDs.isEmpty {
          let placeholder = placeholders.id(for: id, in: page)
          flow.placeholderID = placeholder
          rows.append(.init(id: placeholder, kind: .text(placeholder: true), parentID: parentID, depth: depth, flowID: id))
          flowOfRow[placeholder] = id
        } else {
          numbers.merge(RichDocumentEditing.listItemNumbers(page.pageFlowDocument(blockIDs: blockIDs))) { first, _ in first }
          for blockID in blockIDs {
            let isTable: Bool = if case .table? = blocks[blockID] { true } else { false }
            rows.append(.init(id: blockID, kind: isTable ? .table : .text(placeholder: false), parentID: parentID, depth: depth, flowID: id))
            flowOfRow[blockID] = id
          }
        }
        flows[id] = flow
      case let .section(id, parentID, depth):
        rows.append(.init(id: id, kind: .section, parentID: parentID, depth: depth))
      case let .asset(id, assetID, parentID, depth):
        rows.append(.init(id: id, kind: .asset(assetID), parentID: parentID, depth: depth))
      }
    }
    self.rows = rows; self.flows = flows; self.flowOfRow = flowOfRow; listNumbers = numbers
  }

  func flow(containing id: String) -> MobilePageFlow? { flowOfRow[id].flatMap { flows[$0] } }

  /// The Page's segments plus an empty writing place before any section or
  /// original that no text precedes, matching the Mac editor.
  private static func editorSegments(_ page: NoteDocument) -> [PageSegment] {
    var result: [PageSegment] = []
    var previous: [String?: (flow: Bool, id: String?)] = [:]
    for segment in page.pageSegments {
      let container = segment.parentID
      if case .flow = segment { previous[container] = (true, nil) }
      else {
        if previous[container]?.flow != true {
          let after = previous[container]?.id
          result.append(.flow(id: PageSegment.flowID(parentID: container, afterID: after), parentID: container,
            afterID: after, depth: segment.depth, blockIDs: []))
        }
        previous[container] = (false, segment.id)
      }
      result.append(segment)
    }
    return result
  }
}

extension BoardTaskStatus {
  var mobileTitle: String {
    switch self {
    case .todo: "To do"
    case .doing: "In progress"
    case .blocked: "Blocked"
    case .done: "Done"
    case .canceled: "Canceled"
    }
  }
}

extension BoardItem {
  /// A checkbox already shows to do and done, so only other states need words.
  var hasMobileSummary: Bool {
    if review == .needed || role == .instructions || lastChange?.isEmpty == false { return true }
    guard let task else { return false }
    return ![.todo, .done].contains(task.status) || !task.assignee.isEmpty || !task.outcome.isEmpty
  }
}
