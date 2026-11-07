import Foundation

public enum BoardItemRole: String, Codable, CaseIterable, Sendable { case content, instructions }
public enum BoardTaskStatus: String, Codable, CaseIterable, Sendable { case todo, doing, blocked, done, canceled }
public enum BoardReviewState: String, Codable, CaseIterable, Sendable { case needed, approved, dismissed }

/// Attribution for people reading a Board. It is stamped by the writing host and
/// never authenticates anyone or grants any capability.
public struct BoardActor: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case user, session, outside }
  public var kind: Kind
  /// Stable conversation ID when `kind` is `.session`.
  public var sessionID: String?
  public var label: String?
  public init(kind: Kind, sessionID: String? = nil, label: String? = nil) {
    self.kind = kind; self.sessionID = sessionID; self.label = label
  }
  var isValid: Bool {
    (sessionID?.utf8.count ?? 0) <= 1024 && (label?.utf8.count ?? 0) <= 1024
  }
  /// True only when both writes demonstrably came from one participant. A label can
  /// change, and outside agents share one identity, so neither can show continuity.
  func isSameParticipant(as other: BoardActor) -> Bool {
    switch (kind, other.kind) {
    case (.user, .user): true
    case (.session, .session): sessionID != nil && sessionID == other.sessionID
    default: false
    }
  }
}

public struct BoardTask: Codable, Equatable, Sendable {
  public static let maximumOutcomeBytes = 16 * 1_024
  public var status: BoardTaskStatus
  public var assignee: String
  public var outcome: String
  public init(status: BoardTaskStatus = .todo, assignee: String = "", outcome: String = "") {
    self.status = status; self.assignee = assignee; self.outcome = outcome
  }
  private enum CodingKeys: String, CodingKey { case status, assignee, outcome }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    status = try values.decodeIfPresent(BoardTaskStatus.self, forKey: .status) ?? .todo
    assignee = try values.decodeIfPresent(String.self, forKey: .assignee) ?? ""
    outcome = try values.decodeIfPresent(String.self, forKey: .outcome) ?? ""
  }
  var isValid: Bool { assignee.utf8.count <= 1024 && outcome.utf8.count <= Self.maximumOutcomeBytes }
}

/// Collaboration metadata for one Board card, keyed by its stable block ID. The
/// card's content stays an ordinary note block; a linked asset stays in placement.
public struct BoardItem: Codable, Equatable, Sendable {
  public static let maximumSessions = 32
  public static let maximumLastChangeBytes = 512
  public var role: BoardItemRole
  public var task: BoardTask?
  public var review: BoardReviewState?
  /// Stable conversation IDs. Their run state is read live, never stored here.
  public var sessions: [String]
  public var lastChange: String?
  public var createdBy: BoardActor?
  public var createdAt: String?
  public var updatedBy: BoardActor?
  public var updatedAt: String?

  public init(role: BoardItemRole = .content, task: BoardTask? = nil, review: BoardReviewState? = nil,
              sessions: [String] = [], lastChange: String? = nil, createdBy: BoardActor? = nil, createdAt: String? = nil,
              updatedBy: BoardActor? = nil, updatedAt: String? = nil) {
    self.role = role; self.task = task; self.review = review; self.sessions = sessions; self.lastChange = lastChange
    self.createdBy = createdBy; self.createdAt = createdAt; self.updatedBy = updatedBy; self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case role, task, review, sessions, lastChange, createdBy, createdAt, updatedBy, updatedAt
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    role = try values.decodeIfPresent(BoardItemRole.self, forKey: .role) ?? .content
    task = try values.decodeIfPresent(BoardTask.self, forKey: .task)
    review = try values.decodeIfPresent(BoardReviewState.self, forKey: .review)
    sessions = try values.decodeIfPresent([String].self, forKey: .sessions) ?? []
    lastChange = try values.decodeIfPresent(String.self, forKey: .lastChange)
    createdBy = try values.decodeIfPresent(BoardActor.self, forKey: .createdBy)
    createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    updatedBy = try values.decodeIfPresent(BoardActor.self, forKey: .updatedBy)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  var isValid: Bool {
    sessions.count <= Self.maximumSessions && Set(sessions).count == sessions.count
      && sessions.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1024 }
      && (lastChange?.utf8.count ?? 0) <= Self.maximumLastChangeBytes
      && (task?.isValid ?? true)
      && (createdBy?.isValid ?? true) && (updatedBy?.isValid ?? true)
      && (createdAt?.utf8.count ?? 0) <= 64 && (updatedAt?.utf8.count ?? 0) <= 64
  }
}

/// Supplied fields change; omitted fields stay as they are. There are deliberately
/// no provenance fields: the writing host stamps those from the actual caller.
public struct BoardItemPatch: Codable, Equatable, Sendable {
  public var title: String?
  /// Replaces an inline text card's text. Linked assets are edited at their original.
  public var text: String?
  public var role: BoardItemRole?
  /// Supplying any task field makes the card a task when it is not already one.
  public var status: BoardTaskStatus?
  public var assignee: String?
  public var outcome: String?
  public var clearTask: Bool?
  public var review: BoardReviewState?
  public var clearReview: Bool?
  public var lastChange: String?
  public init(title: String? = nil, text: String? = nil, role: BoardItemRole? = nil, status: BoardTaskStatus? = nil,
              assignee: String? = nil, outcome: String? = nil, clearTask: Bool? = nil, review: BoardReviewState? = nil,
              clearReview: Bool? = nil, lastChange: String? = nil) {
    self.title = title; self.text = text; self.role = role; self.status = status
    self.assignee = assignee; self.outcome = outcome; self.clearTask = clearTask
    self.review = review; self.clearReview = clearReview; self.lastChange = lastChange
  }
}

/// A focused Board mutation. `updateItem` and `removeItem` carry the item revision
/// that was read, so independent cards do not contend on the document revision.
public struct BoardEdit: Codable, Equatable, Sendable {
  /// `requireBoard` changes nothing. It makes a batch of generic operations fail on
  /// any other asset inside the same transaction, so a successful retry still replays.
  public enum Action: String, Codable, Sendable { case requireBoard, setPurpose, addItem, updateItem, removeItem, linkSession, unlinkSession }
  public var action: Action
  public var id: String?
  public var expectedRevision: String?
  /// `setPurpose` only; an empty value clears the purpose.
  public var purpose: String?
  public var patch: BoardItemPatch?
  /// `addItem` only. An existing card's linked asset is never retargeted.
  public var assetID: String?
  /// `addItem` only; omitted means the next free position on the Board.
  public var placement: CanvasCardPlacement?
  public var sessionID: String?
  public init(action: Action, id: String? = nil, expectedRevision: String? = nil, purpose: String? = nil,
              patch: BoardItemPatch? = nil, assetID: String? = nil, placement: CanvasCardPlacement? = nil, sessionID: String? = nil) {
    self.action = action; self.id = id; self.expectedRevision = expectedRevision; self.purpose = purpose
    self.patch = patch; self.assetID = assetID; self.placement = placement; self.sessionID = sessionID
  }
}

public extension NoteDocument {
  static let maximumBoardPurposeBytes = 4_096
  /// Agent writes cannot exceed the note edit envelope, so the editor must not
  /// grow a Board past the size every other participant can still change.
  static let maximumBoardBytes = RemoteNoteEditEnvelope.maximumEnvelopeBytes

  /// Portable token for one card's content and metadata. Moving, resizing, recoloring
  /// or regrouping a card keeps it; so a layout change never conflicts with a task
  /// update. Returns an empty string for a card that does not exist.
  func boardItemRevision(for id: String) -> String {
    guard let block = blocks.first(where: { $0.id == id }) else { return "" }
    return pageRevision(of: block)
  }

  /// Stamps cards whose content or metadata differ from `old`, restores provenance
  /// on every other card, and drops metadata of cards that no longer exist.
  /// Layout-only changes are not stamped. Call once per write with its actual actor.
  /// A summary stays while the participant who last changed the card keeps editing it.
  /// Another participant's change clears it unless that change supplies different text.
  mutating func stampBoardChanges(from old: NoteDocument, actor: BoardActor,
                                  at timestamp: String = ISO8601DateFormatter().string(from: Date())) {
    guard kind == .canvas else { return }
    // One lookup per card keeps this linear; the editor stamps on every keystroke.
    let oldBlocks = Dictionary(old.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newBlocks = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var items: [String: BoardItem] = [:]
    for block in blocks {
      let id = block.id, previous = old.boardItems?[id]
      var current = boardItems?[id]
      // Only this function writes provenance; a supplied value never survives.
      current?.createdBy = previous?.createdBy; current?.createdAt = previous?.createdAt
      current?.updatedBy = previous?.updatedBy; current?.updatedAt = previous?.updatedAt
      let isNew = oldBlocks[id] == nil
      guard isNew || old.boardContent(for: id, block: oldBlocks[id]) != boardContent(for: id, block: newBlocks[id]) else {
        if let current { items[id] = current }
        continue
      }
      var item = current ?? BoardItem()
      // A summary carried over from another participant does not describe this change.
      let continuing = previous?.updatedBy?.isSameParticipant(as: actor) == true
      if !isNew, !continuing, item.lastChange == previous?.lastChange { item.lastChange = nil }
      if isNew { item.createdBy = actor; item.createdAt = timestamp }
      item.updatedBy = actor; item.updatedAt = timestamp
      items[id] = item
    }
    boardItems = items.isEmpty && boardItems == nil ? nil : items
  }

  /// The next card position that overlaps nothing, inside `sectionID` when it fits.
  func nextBoardPlacement(sectionID: String? = nil) -> CanvasCardPlacement {
    let width = 360.0, height = 300.0, gap = 32.0
    let section = sectionID.flatMap { id in canvasSections?.first { $0.id == id } }
    let originX = section.map { $0.x + 24 } ?? 24, originY = section.map { $0.y + 56 } ?? 24
    let columns = section.map { max(1, Int(($0.width - 48 + gap) / (width + gap))) } ?? 5
    let occupied = Array(canvasPlacements.values)
    func placed(x: Double, y: Double) -> CanvasCardPlacement {
      var placement = CanvasCardPlacement(x: x, y: y, width: width, height: height)
      placement.sectionID = section?.id
      return placement
    }
    // One card can straddle several cells, so try a bounded grid, then go below everything.
    for index in 0..<(occupied.count * 4 + 1) {
      let x = originX + Double(index % columns) * (width + gap), y = originY + Double(index / columns) * (height + gap)
      if !occupied.contains(where: { $0.x < x + width && x < $0.x + $0.width && $0.y < y + height && y < $0.y + $0.height }) {
        return placed(x: x, y: y)
      }
    }
    return placed(x: originX, y: max(originY, (occupied.map { $0.y + $0.height }.max() ?? originY) + gap))
  }

  mutating func applyBoardEdit(_ edit: BoardEdit) throws {
    guard kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    switch edit.action {
    case .requireBoard:
      break
    case .setPurpose:
      guard let purpose = edit.purpose, purpose.utf8.count <= Self.maximumBoardPurposeBytes else { throw NoteDocumentSafetyError.tooLarge }
      boardPurpose = purpose.isEmpty ? nil : purpose
    case .addItem:
      guard let id = edit.id, !id.isEmpty, id.utf8.count <= 1024 else { throw NoteDocumentSafetyError.unsupportedFormat }
      guard !blocks.contains(where: { $0.id == id }) else { throw NoteEditError.boardItemExists(id) }
      if edit.assetID != nil, edit.patch?.text != nil { throw NoteEditError.boardLinkedAssetText(id) }
      if edit.assetID?.isEmpty == true { throw NoteDocumentSafetyError.unsupportedFormat }
      var placement = edit.placement ?? nextBoardPlacement()
      placement.assetID = edit.assetID
      if let title = edit.patch?.title { placement.title = title }
      blocks.append(.richText(NoteRichTextBlock(id: id, text: edit.patch?.text ?? "")))
      if canvas == nil { canvas = [:] }
      canvas?[id] = placement
      var item = BoardItem()
      try applyBoardPatch(edit.patch, to: &item)
      if boardItems == nil { boardItems = [:] }
      boardItems?[id] = item
    case .updateItem:
      let id = try requireBoardItem(edit, revisionRequired: true)
      guard let patch = edit.patch else { throw NoteDocumentSafetyError.unsupportedFormat }
      if let title = patch.title {
        var placement = canvasPlacement(for: id); placement.title = title.isEmpty ? nil : title
        if canvas == nil { canvas = [:] }
        canvas?[id] = placement
      }
      if let text = patch.text {
        guard canvasPlacement(for: id).assetID == nil else { throw NoteEditError.boardLinkedAssetText(id) }
        guard let index = blocks.firstIndex(where: { $0.id == id }), case .richText(var block) = blocks[index] else {
          throw NoteEditError.boardItemNotText(id)
        }
        if block.plainText != text { block.runs = text.isEmpty ? [] : [NoteTextRun(text: text)]; blocks[index] = .richText(block) }
      }
      var item = boardItems?[id] ?? BoardItem()
      try applyBoardPatch(patch, to: &item)
      if boardItems == nil { boardItems = [:] }
      boardItems?[id] = item
    case .removeItem:
      let id = try requireBoardItem(edit, revisionRequired: true)
      try requirePageRemovable(id)
      blocks.removeAll { $0.id == id }
      prunePageMetadata([id])
    case .linkSession:
      let id = try requireBoardItem(edit, revisionRequired: false)
      guard let sessionID = edit.sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 1024 else { throw NoteDocumentSafetyError.unsupportedFormat }
      var item = boardItems?[id] ?? BoardItem()
      guard !item.sessions.contains(sessionID) else { return }
      guard item.sessions.count < BoardItem.maximumSessions else { throw NoteEditError.boardSessionLimit(id) }
      item.sessions.append(sessionID)
      if boardItems == nil { boardItems = [:] }
      boardItems?[id] = item
    case .unlinkSession:
      let id = try requireBoardItem(edit, revisionRequired: false)
      guard let sessionID = edit.sessionID else { throw NoteDocumentSafetyError.unsupportedFormat }
      boardItems?[id]?.sessions.removeAll { $0 == sessionID }
    }
  }

  /// Checks identity and the optimistic item revision against the document being edited.
  private func requireBoardItem(_ edit: BoardEdit, revisionRequired: Bool) throws -> String {
    guard let id = edit.id else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard blocks.contains(where: { $0.id == id }) else {
      // A caller holding a revision read this card, so it was removed since then.
      if edit.expectedRevision != nil { throw NoteEditError.boardItemConflict(id: id, currentRevision: "") }
      throw NoteEditError.blockNotFound(id)
    }
    if revisionRequired, edit.expectedRevision == nil {
      throw WorkspaceToolError.revisionRequired("This Board change requires itemRevision. Read the Board and pass the item's current revision.")
    }
    if let expected = edit.expectedRevision {
      let current = boardItemRevision(for: id)
      guard expected == current else { throw NoteEditError.boardItemConflict(id: id, currentRevision: current) }
    }
    return id
  }

  internal func applyBoardPatch(_ patch: BoardItemPatch?, to item: inout BoardItem) throws {
    guard let patch else { return }
    if let role = patch.role { item.role = role }
    let changesTask = patch.status != nil || patch.assignee != nil || patch.outcome != nil
    if patch.clearTask == true {
      guard !changesTask else { throw NoteEditError.boardConflictingPatch("clearTask cannot be combined with task fields.") }
      item.task = nil
    } else if changesTask {
      var task = item.task ?? BoardTask()
      if let status = patch.status { task.status = status }
      if let assignee = patch.assignee { task.assignee = assignee }
      if let outcome = patch.outcome { task.outcome = outcome }
      item.task = task
    }
    if patch.clearReview == true {
      guard patch.review == nil else { throw NoteEditError.boardConflictingPatch("clearReview cannot be combined with review.") }
      item.review = nil
    } else if let review = patch.review { item.review = review }
    if let lastChange = patch.lastChange { item.lastChange = lastChange.isEmpty ? nil : lastChange }
  }

  /// Compares everything a stamp reflects, and nothing a stamp writes or layout moves.
  private func boardContent(for id: String, block: NoteBlock?) -> BoardItemContent {
    // A card with no stored placement has an automatic one, with no title or asset.
    let placement = canvas?[id]
    let item = boardItems?[id] ?? BoardItem()
    return BoardItemContent(block: block?.normalized, title: placement?.title, assetID: placement?.assetID,
      role: item.role, task: item.task, review: item.review, sessions: item.sessions, lastChange: item.lastChange)
  }
}

/// `isSection` is omitted unless true, so tokens of every other block stay stable.
struct BoardItemFingerprint: Encodable {
  let block: NoteBlock
  let title: String?
  let assetID: String?
  let item: BoardItem?
  let isSection: Bool?
}

private struct BoardItemContent: Equatable {
  let block: NoteBlock?
  let title: String?
  let assetID: String?
  let role: BoardItemRole
  let task: BoardTask?
  let review: BoardReviewState?
  let sessions: [String]
  let lastChange: String?
}
