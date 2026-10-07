import Foundation

/// Chronological, display-ready projection of one run's work activity.
///
/// The projection is pure and `Sendable`, so a caller can build it once off the
/// main actor from the run's activity records and pass it to the transcript
/// view. Commentary is inline; thoughts and tool calls between commentary
/// segments form one work group (as in T3's work log); plans, progress, and
/// agent activity remain standalone rows. File changes are excluded and stay
/// with the changed-files card.
public struct ConversationWorkTimeline: Equatable, Sendable {
  public static let empty = Self(entries: [])

  public let entries: [ConversationWorkTimelineEntry]
  /// Entries that stay visible while a settled run is folded behind its
  /// "Worked for" header: failed rows and the failed calls of each group.
  public let foldedEntries: [ConversationWorkTimelineEntry]

  public var hasVisibleActivities: Bool { !entries.isEmpty }

  /// Merges `records` in `WorkspaceRunActivityRecord.precedes` order. Snapshot
  /// and delta updates merge by activity ID, a `clear` update removes the
  /// activity, and assistant segments appear only when their ID is in
  /// `commentaryIDs` (the final reply is rendered outside the transcript).
  public init(records: [WorkspaceRunActivityRecord], commentaryIDs: Set<String>) {
    self.init(entries: Self.entries(
      for: Self.mergedActivities(in: records, commentaryIDs: commentaryIDs)
    ))
  }

  init(entries: [ConversationWorkTimelineEntry]) {
    self.entries = entries
    foldedEntries = entries.compactMap { entry in
      switch entry.content {
      case .commentary:
        return nil
      case .activity(let activity):
        return activity.workTimelineIsFailure ? entry : nil
      case .group(let group):
        let failed = group.activities.filter(\.workTimelineIsFailure)
        guard !failed.isEmpty else { return nil }
        return ConversationWorkTimelineEntry(
          content: .group(ConversationWorkGroup(id: "failed:\(group.id)", activities: failed))
        )
      }
    }
  }

  /// Merged activities in first-appearance order, excluding cleared items.
  public static func mergedActivities(
    in records: [WorkspaceRunActivityRecord],
    commentaryIDs: Set<String>
  ) -> [AgentRunActivity] {
    var order: [String] = []
    var values: [String: AgentRunActivity] = [:]
    var cleared: Set<String> = []
    for record in records.sorted(by: WorkspaceRunActivityRecord.precedes) {
      let update = record.activity
      guard update.kind != .assistant || commentaryIDs.contains(update.id) else { continue }
      if update.phase == "clear" {
        // Keep the merged value so a later update restores the cleared
        // item from the clear's reset state rather than from stale entries.
        if let prior = values[update.id] { values[update.id] = prior.merging(update) }
        cleared.insert(update.id)
        continue
      }
      cleared.remove(update.id)
      if let prior = values[update.id] {
        values[update.id] = prior.merging(update)
      } else {
        order.append(update.id)
        values[update.id] = update
      }
    }
    return order.compactMap { cleared.contains($0) ? nil : values[$0] }
  }

  static func entries(for activities: [AgentRunActivity]) -> [ConversationWorkTimelineEntry] {
    var entries: [ConversationWorkTimelineEntry] = []
    var pending: [AgentRunActivity] = []
    func flush() {
      guard let first = pending.first else { return }
      // A group keeps the first member's ID as it grows, so disclosure state
      // survives start/result updates and additional calls.
      entries.append(ConversationWorkTimelineEntry(
        content: .group(ConversationWorkGroup(id: "group:\(first.id)", activities: pending))
      ))
      pending.removeAll(keepingCapacity: true)
    }
    for activity in activities {
      switch activity.kind {
      case .fileChange:
        continue
      case .tool:
        pending.append(activity)
      case .thought:
        // Empty reasoning has nothing to disclose (T3 `workEntryIsVisibleInGroup`).
        if activity.workTimelineThoughtHasText { pending.append(activity) }
      case .assistant:
        flush()
        guard activity.content?.workTimelineNonempty != nil else { continue }
        entries.append(ConversationWorkTimelineEntry(content: .commentary(activity)))
      case .plan, .progress, .activity:
        flush()
        entries.append(ConversationWorkTimelineEntry(content: .activity(activity)))
      }
    }
    flush()
    return entries
  }
}

public struct ConversationWorkTimelineEntry: Equatable, Identifiable, Sendable {
  public enum Content: Equatable, Sendable {
    /// Frozen assistant commentary preceding later work.
    case commentary(AgentRunActivity)
    /// Contiguous thoughts and tool calls.
    case group(ConversationWorkGroup)
    /// A plan, progress, or agent activity row.
    case activity(AgentRunActivity)
  }

  public let content: Content

  public var id: String {
    switch content {
    case .commentary(let activity): "commentary:\(activity.id)"
    case .group(let group): group.id
    case .activity(let activity): "activity:\(activity.id)"
    }
  }
}

/// Contiguous thoughts and tool calls, summarized as T3 summarizes a work
/// group: at most two action categories, prioritizing commands and edits,
/// with the remaining calls counted as other actions.
public struct ConversationWorkGroup: Equatable, Identifiable, Sendable {
  public let id: String
  public let activities: [AgentRunActivity]
  /// Settled summary, such as "Ran 3 commands and read 2 files".
  public let summary: String
  /// The single action shared by every tool call, for the summary icon.
  public let action: ConversationToolAction?
  public let isThoughtOnly: Bool
  /// The latest tool call failed (T3 marks the group, not every member).
  public let hasFailure: Bool

  public init(id: String, activities: [AgentRunActivity]) {
    self.id = id
    self.activities = activities
    let tools = activities.filter { $0.kind != .thought }
    isThoughtOnly = tools.isEmpty
    let actions = Set(tools.map(ConversationToolAction.init))
    action = actions.count == 1 ? actions.first : nil
    hasFailure = tools.last?.workTimelineIsFailure ?? false
    summary = Self.summary(activities: activities, tools: tools)
  }

  /// The single member shown without a group disclosure (T3 shows a lone
  /// call or thought as its own row; a lone edit keeps the file summary).
  public var singleActivity: AgentRunActivity? {
    guard activities.count == 1, let only = activities.first else { return nil }
    return only.kind == .tool && ConversationToolAction(only) == .edit ? nil : only
  }

  /// Label for a group that is still part of the active response: the latest
  /// running call in the present tense, otherwise the latest call settled.
  public func liveLabel(runIsActive: Bool) -> String? {
    guard runIsActive else { return nil }
    if let running = activities.last(where: \.workTimelineShowsProgress) {
      return running.workTimelineLabel(active: true)
    }
    return activities.last?.workTimelineLabel(active: false)
  }

  public var hasActiveActivity: Bool { activities.contains(where: \.workTimelineShowsProgress) }

  static func summary(activities: [AgentRunActivity], tools: [AgentRunActivity]) -> String {
    if tools.isEmpty {
      if activities.count == 1, let only = activities.first {
        return only.workTimelineLabel(active: false)
      }
      return "Thought (×\(activities.count))"
    }
    var order: [ConversationToolAction] = []
    var members: [ConversationToolAction: [AgentRunActivity]] = [:]
    for tool in tools {
      let action = ConversationToolAction(tool)
      if members[action] == nil { order.append(action) }
      members[action, default: []].append(tool)
    }
    let selected = order.enumerated()
      .sorted { ($0.element.summaryPriority, $0.offset) < ($1.element.summaryPriority, $1.offset) }
      .prefix(2)
      .sorted { $0.offset < $1.offset }
      .map(\.element)
    var labels = selected.map { action in
      action.summary(count: action.summaryCount(members[action] ?? []))
    }
    let remaining = tools.count - selected.reduce(0) { $0 + (members[$1]?.count ?? 0) }
    if remaining > 0 {
      labels.append("Performed \(remaining) other \(remaining == 1 ? "action" : "actions")")
    }
    let sentence = labels.enumerated().map { index, label in
      index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
    }
    if sentence.count < 3 { return sentence.joined(separator: " and ") }
    return sentence.dropLast().joined(separator: ", ") + ", and " + (sentence.last ?? "")
  }
}

/// T3's tool-group action categories, classified from the tool name or title.
public enum ConversationToolAction: Hashable, Sendable {
  case command
  case read
  case edit
  case codeSearch
  case webSearch
  case webFetch
  case delegate
  case other

  public init(_ activity: AgentRunActivity) {
    let name = (activity.toolName ?? activity.title ?? "").lowercased()
    if name.contains("bash") || name.contains("shell") || name == "exec"
      || name.contains("command") || name.contains("terminal") {
      self = .command
    } else if name.contains("websearch") || name.contains("web_search") || name.contains("web search") {
      self = .webSearch
    } else if name.contains("web") || name.contains("fetch") || name.contains("browse") {
      self = .webFetch
    } else if name.contains("grep") || name.contains("glob")
      || name.contains("search") || name.contains("find") {
      self = .codeSearch
    } else if name.contains("write") || name.contains("edit")
      || name.contains("patch") || !activity.changes.isEmpty {
      self = .edit
    } else if name.contains("read") || name.contains("view") {
      self = .read
    } else if name.contains("task") || name.contains("agent") {
      self = .delegate
    } else {
      self = .other
    }
  }

  var summaryPriority: Int {
    switch self {
    case .command, .edit, .delegate: 0
    case .other: 2
    default: 1
    }
  }

  /// Edits count distinct files, plus each edit that names no file.
  func summaryCount(_ activities: [AgentRunActivity]) -> Int {
    guard self == .edit else { return activities.count }
    var paths: Set<String> = []
    var unnamed = 0
    for activity in activities {
      let named = activity.changes.map(\.path) + activity.locations.map(\.path)
      if named.isEmpty { unnamed += 1 } else { paths.formUnion(named) }
    }
    return paths.count + unnamed
  }

  public func summary(count: Int) -> String {
    let plural = count != 1
    return switch self {
    case .command: "Ran \(count) \(plural ? "commands" : "command")"
    case .read: "Read \(count) \(plural ? "files" : "file")"
    case .edit: "Changed \(count) \(plural ? "files" : "file")"
    case .codeSearch: "Searched code \(count) \(plural ? "times" : "time")"
    case .webSearch: "Searched the web \(count) \(plural ? "times" : "time")"
    case .webFetch: "Fetched \(count) web \(plural ? "pages" : "page")"
    case .delegate: "Delegated \(count) \(plural ? "tasks" : "task")"
    case .other: "Used \(count) \(plural ? "tools" : "tool")"
    }
  }

  func liveLabel(active: Bool) -> String {
    switch self {
    case .command: active ? "Running a command" : "Ran a command"
    case .read: active ? "Reading a file" : "Read a file"
    case .edit: active ? "Editing a file" : "Edited a file"
    case .codeSearch: active ? "Searching code" : "Searched code"
    case .webSearch: active ? "Searching the web" : "Searched the web"
    case .webFetch: active ? "Fetching a web page" : "Fetched a web page"
    case .delegate: active ? "Delegating a task" : "Delegated a task"
    case .other: active ? "Using a tool" : "Used a tool"
    }
  }
}

public extension AgentRunActivity {
  /// Whether the activity is still pending or running, by status or phase.
  var workTimelineShowsProgress: Bool {
    let value = (status ?? phase ?? "").lowercased()
    return ["pending", "in_progress", "inprogress", "in-progress", "running", "started", "start"]
      .contains(value)
  }

  var workTimelineIsFailure: Bool {
    ["failed", "error", "cancelled", "canceled"].contains(status?.lowercased() ?? "")
  }

  /// A meaningful one-line label: the provider title, else for a thought its
  /// detail or leading bold heading, else a category phrase.
  func workTimelineLabel(active: Bool) -> String {
    switch kind {
    case .thought:
      if let title = title?.workTimelineSingleLine,
         !["thinking", "thought", "reasoning"].contains(title.lowercased()) {
        return title
      }
      if let detail = detail?.workTimelineSingleLine { return detail }
      if let heading = content.flatMap(Self.leadingBoldHeading) { return heading }
      return active ? "Thinking" : "Thought"
    case .tool:
      if let label = (title ?? toolName)?.workTimelineSingleLine { return label }
      return ConversationToolAction(self).liveLabel(active: active)
    default:
      return title?.workTimelineSingleLine ?? toolName?.workTimelineSingleLine ?? "Agent activity"
    }
  }

  internal var workTimelineThoughtHasText: Bool {
    title?.workTimelineNonempty != nil || detail?.workTimelineNonempty != nil
      || content?.workTimelineNonempty != nil
  }

  /// Reasoning summaries often open with `**Heading**`; use it as the label.
  internal static func leadingBoldHeading(_ text: String) -> String? {
    let trimmed = text.drop { $0.isWhitespace }
    guard trimmed.hasPrefix("**") else { return nil }
    let rest = trimmed.dropFirst(2)
    guard let end = rest.range(of: "**") else { return nil }
    let heading = rest[..<end.lowerBound]
    guard !heading.contains("\n") else { return nil }
    return String(heading).workTimelineSingleLine
  }
}

extension String {
  var workTimelineNonempty: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }

  /// Whitespace collapsed to single spaces, or nil when empty.
  var workTimelineSingleLine: String? {
    let line = split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.isEmpty ? nil : line
  }
}
