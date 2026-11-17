import CryptoKit
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

public extension BoardTaskStatus {
  /// What people see. `blocked` means the task waits on the person; `canceled`
  /// is read from older Boards only, since a task nobody needs is removed.
  var displayName: String {
    switch self {
    case .todo: "To do"
    case .doing: "In progress"
    case .blocked: "Needs input"
    case .done: "Done"
    case .canceled: "Canceled"
    }
  }
  /// The statuses people and agents choose from.
  static let current: [BoardTaskStatus] = [.todo, .doing, .blocked, .done]
}

/// Someone a task is assigned to: the person, an agent on one workspace, or a bot.
/// An agent or bot gets its own new chat or thread when the task is sent. The IDs
/// it is sent to are fixed when it is assigned, so sending twice from two places
/// reaches the same chat instead of starting another.
public struct BoardTaskAssignee: Codable, Equatable, Identifiable, Sendable {
  public static let maximumTextBytes = 1_024
  public enum Kind: String, Codable, CaseIterable, Sendable { case user, agent, bot }
  /// `assigned` waits for Send. `sending` asks a host to start the chat; `stopping`
  /// asks it to stop that chat or tell the bot it is no longer needed.
  public enum State: String, Codable, CaseIterable, Sendable {
    case assigned, sending, sent, stopping, stopped, failed
    /// Later states win when two writers changed one assignee at once.
    var rank: Int {
      switch self {
      case .assigned: 0
      case .sending: 1
      case .failed: 2
      case .sent: 3
      case .stopping: 4
      case .stopped: 5
      }
    }
  }
  public var id: String
  public var kind: Kind
  /// The agent's or bot's name, such as Claude Code. Empty for the person.
  public var name: String
  /// Where the agent runs, such as a Mac's name. Display only.
  public var place: String?
  public var workspaceID: String?
  /// The agent runtime, such as `claude_code`.
  public var runtime: String?
  /// The folder the new chat starts in.
  public var folderID: String?
  public var botID: String?
  /// The bot's machine, which routes its threads.
  public var machineID: String?
  /// The chat this agent works in, fixed when it is assigned. A bot's thread
  /// number is known once the bot starts it.
  public var conversationID: String?
  public var state: State
  /// Why the last send or stop failed.
  public var message: String?
  public var assignedBy: BoardActor?
  public var assignedAt: String?

  public init(id: String = UUID().uuidString.lowercased(), kind: Kind, name: String = "", place: String? = nil,
              workspaceID: String? = nil, runtime: String? = nil, folderID: String? = nil, botID: String? = nil,
              machineID: String? = nil, conversationID: String? = nil, state: State = .assigned, message: String? = nil,
              assignedBy: BoardActor? = nil, assignedAt: String? = nil) {
    self.id = id; self.kind = kind; self.name = name; self.place = place; self.workspaceID = workspaceID
    self.runtime = runtime; self.folderID = folderID; self.botID = botID; self.machineID = machineID
    self.conversationID = conversationID ?? (kind == .agent ? Self.conversationID(for: id) : nil)
    self.state = state; self.message = message; self.assignedBy = assignedBy; self.assignedAt = assignedAt
  }

  /// The same agent in the same place, or the same bot; two of these are one assignment.
  public func isSameTarget(as other: BoardTaskAssignee) -> Bool {
    kind == other.kind && workspaceID == other.workspaceID && runtime == other.runtime
      && botID == other.botID && (kind != .user || other.kind == .user)
  }

  /// Still working on the task, or about to.
  public var isActive: Bool { state == .sending || state == .sent }

  /// The name people know an agent runtime by.
  public static func runtimeName(_ runtime: String) -> String {
    switch runtime {
    case "default_agent": "Pi Durable"
    case "codex": "Codex"
    case "claude_code": "Claude Code"
    case "grok_build": "Grok Build"
    case "opencode": "OpenCode"
    default: runtime
    }
  }

  /// A conversation UUID that every host derives the same way from one assignment.
  public static func conversationID(for assigneeID: String) -> String {
    var bytes = Array(SHA256.hash(data: Data("woven-page-task-v1\u{0}\(assigneeID)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
  }

  var isValid: Bool {
    let texts = [id, name, place, workspaceID, runtime, folderID, botID, machineID, conversationID, message, assignedAt]
    return !id.isEmpty && texts.allSatisfy { ($0?.utf8.count ?? 0) <= Self.maximumTextBytes }
      && (assignedBy?.isValid ?? true)
      && (kind != .agent || (workspaceID?.isEmpty == false && runtime?.isEmpty == false && conversationID?.isEmpty == false))
      && (kind != .bot || (botID?.isEmpty == false && machineID?.isEmpty == false))
  }
}

public struct BoardTask: Codable, Equatable, Sendable {
  public static let maximumOutcomeBytes = 16 * 1_024
  public static let maximumDetailsBytes = 16 * 1_024
  public static let maximumAssignees = 16
  public var status: BoardTaskStatus
  /// A free-text label from older Boards. New assignments use `assignees`.
  public var assignee: String
  public var outcome: String
  /// What the task asks for, beyond its title. Sent with the task.
  public var details: String
  public var assignees: [BoardTaskAssignee]
  public init(status: BoardTaskStatus = .todo, assignee: String = "", outcome: String = "", details: String = "",
              assignees: [BoardTaskAssignee] = []) {
    self.status = status; self.assignee = assignee; self.outcome = outcome; self.details = details; self.assignees = assignees
  }
  private enum CodingKeys: String, CodingKey { case status, assignee, outcome, details, assignees }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    status = try values.decodeIfPresent(BoardTaskStatus.self, forKey: .status) ?? .todo
    assignee = try values.decodeIfPresent(String.self, forKey: .assignee) ?? ""
    outcome = try values.decodeIfPresent(String.self, forKey: .outcome) ?? ""
    details = try values.decodeIfPresent(String.self, forKey: .details) ?? ""
    assignees = try values.decodeIfPresent([BoardTaskAssignee].self, forKey: .assignees) ?? []
  }
  /// Older readers and fingerprints keep their encoding while a task has no details or assignees.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(status, forKey: .status)
    try values.encode(assignee, forKey: .assignee)
    try values.encode(outcome, forKey: .outcome)
    if !details.isEmpty { try values.encode(details, forKey: .details) }
    if !assignees.isEmpty { try values.encode(assignees, forKey: .assignees) }
  }
  var isValid: Bool {
    assignee.utf8.count <= 1024 && outcome.utf8.count <= Self.maximumOutcomeBytes
      && details.utf8.count <= Self.maximumDetailsBytes && assignees.count <= Self.maximumAssignees
      && Set(assignees.map(\.id)).count == assignees.count && assignees.allSatisfy(\.isValid)
  }

  /// Combines two writers' assignees. Each assignee merges on its own: one side's
  /// additions and removals both stay, and a later state wins over an earlier one.
  static func mergeAssignees(base: [BoardTaskAssignee], local: [BoardTaskAssignee], remote: [BoardTaskAssignee]) -> [BoardTaskAssignee] {
    let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let r = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [BoardTaskAssignee] = []
    var seen = Set<String>()
    for id in (remote + local).map(\.id) where seen.insert(id).inserted {
      switch (l[id], r[id]) {
      case let (local?, remote?):
        if local == remote || local == b[id] { result.append(remote) }
        else if remote == b[id] { result.append(local) }
        else {
          var merged = remote
          if local.state.rank > remote.state.rank { merged.state = local.state; merged.message = local.message }
          result.append(merged)
        }
      case let (local?, nil):
        // Removed remotely: gone unless this side changed it since.
        if b[id] == nil || b[id] != local { result.append(local) }
      case let (nil, remote?):
        if b[id] == nil || b[id] != remote { result.append(remote) }
      case (nil, nil): break
      }
    }
    return Array(result.prefix(maximumAssignees))
  }
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
  public var details: String?
  /// Replaces the task's assignees. Hosts check who may change which assignee.
  public var assignees: [BoardTaskAssignee]?
  public var clearTask: Bool?
  public var review: BoardReviewState?
  public var clearReview: Bool?
  public var lastChange: String?
  public init(title: String? = nil, text: String? = nil, role: BoardItemRole? = nil, status: BoardTaskStatus? = nil,
              assignee: String? = nil, outcome: String? = nil, details: String? = nil, assignees: [BoardTaskAssignee]? = nil,
              clearTask: Bool? = nil, review: BoardReviewState? = nil,
              clearReview: Bool? = nil, lastChange: String? = nil) {
    self.title = title; self.text = text; self.role = role; self.status = status
    self.assignee = assignee; self.outcome = outcome; self.details = details; self.assignees = assignees; self.clearTask = clearTask
    self.review = review; self.clearReview = clearReview; self.lastChange = lastChange
  }
}

extension BoardItemPatch {
  var changesTask: Bool { status != nil || assignee != nil || outcome != nil || details != nil || assignees != nil }
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
      guard isNew || oldBlocks[id].map(old.pageComponentContent) != newBlocks[id].map(pageComponentContent) else {
        if let current { items[id] = current }
        continue
      }
      var item = current ?? BoardItem()
      // A summary carried over from another participant does not describe this change.
      let continuing = previous?.updatedBy?.isSameParticipant(as: actor) == true
      if !isNew, !continuing, item.lastChange == previous?.lastChange { item.lastChange = nil }
      if isNew { item.createdBy = actor; item.createdAt = timestamp }
      item.updatedBy = actor; item.updatedAt = timestamp
      // Who assigned someone is stamped once, by the writer that added them.
      if var task = item.task {
        let earlier = Dictionary((previous?.task?.assignees ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in task.assignees.indices {
          if let old = earlier[task.assignees[index].id] {
            task.assignees[index].assignedBy = old.assignedBy; task.assignees[index].assignedAt = old.assignedAt
          } else {
            task.assignees[index].assignedBy = actor; task.assignees[index].assignedAt = timestamp
          }
        }
        item.task = task
      }
      items[id] = item
    }
    boardItems = items.isEmpty && boardItems == nil ? nil : items
  }

  internal func applyBoardPatch(_ patch: BoardItemPatch?, to item: inout BoardItem) throws {
    guard let patch else { return }
    if let role = patch.role { item.role = role }
    let changesTask = patch.changesTask
    if patch.clearTask == true {
      guard !changesTask else { throw NoteEditError.boardConflictingPatch("clearTask cannot be combined with task fields.") }
      item.task = nil
    } else if changesTask {
      var task = item.task ?? BoardTask()
      if let status = patch.status { task.status = status }
      if let assignee = patch.assignee { task.assignee = assignee }
      if let outcome = patch.outcome { task.outcome = outcome }
      if let details = patch.details { task.details = details }
      if let assignees = patch.assignees { task.assignees = assignees }
      item.task = task
    }
    if patch.clearReview == true {
      guard patch.review == nil else { throw NoteEditError.boardConflictingPatch("clearReview cannot be combined with review.") }
      item.review = nil
    } else if let review = patch.review { item.review = review }
    if let lastChange = patch.lastChange { item.lastChange = lastChange.isEmpty ? nil : lastChange }
  }

  /// Everything a reader sees of one component, which a stamp and a merge compare.
  internal func pageComponentContent(of block: NoteBlock) -> PageComponentContent {
    let placement = canvas?[block.id], item = boardItems?[block.id] ?? BoardItem()
    return PageComponentContent(block: block.normalized, title: placement?.title, assetID: placement?.assetID, role: item.role,
      task: item.task, review: item.review, sessions: item.sessions, lastChange: item.lastChange)
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

/// Everything a reader sees of a component, and nothing a stamp writes or layout moves.
/// Its encoding names conflict copies, so its field names must stay stable.
struct PageComponentContent: Equatable, Encodable {
  var block: NoteBlock
  var title: String?
  var assetID: String?
  var role: BoardItemRole
  var task: BoardTask?
  var review: BoardReviewState?
  var sessions: [String]
  var lastChange: String?
}
