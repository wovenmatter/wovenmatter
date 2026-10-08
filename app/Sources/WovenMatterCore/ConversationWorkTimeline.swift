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
      for: Self.mergedActivities(in: records, commentaryIDs: commentaryIDs),
      hasChecklist: records.contains { $0.activity.kind == .plan && $0.activity.planKind != "proposal" }
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
    var versions: [String: Hasher] = [:]
    for record in records.sorted(by: WorkspaceRunActivityRecord.precedes) {
      let update = record.activity
      guard update.kind != .assistant || commentaryIDs.contains(update.id) else { continue }
      versions[update.id, default: Hasher()].combine(record.id)
      versions[update.id, default: Hasher()].combine(update.detailVersion)
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
    return order.compactMap { id in
      guard !cleared.contains(id), let value = values[id] else { return nil }
      // A legacy activity can comprise several trace records. Corrections or
      // deletion of any contributor must invalidate its cached full detail.
      let version = versions[id] ?? Hasher()
      return value.merging(AgentRunActivity(
        id: id, kind: value.kind, detailVersion: Int64(version.finalize())
      ))
    }
  }

  static func entries(for activities: [AgentRunActivity], hasChecklist: Bool) -> [ConversationWorkTimelineEntry] {
    var entries: [ConversationWorkTimelineEntry] = []
    var pending: [AgentRunActivity] = []
    func flush(endsTimeline: Bool = false) {
      guard let first = pending.first else { return }
      // A group keeps the first member's ID as it grows, so disclosure state
      // survives start/result updates and additional calls.
      entries.append(ConversationWorkTimelineEntry(
        content: .group(ConversationWorkGroup(
          id: "group:\(first.id)", activities: pending, endsTimeline: endsTimeline
        ))
      ))
      pending.removeAll(keepingCapacity: true)
    }
    for activity in activities {
      switch activity.kind {
      case .fileChange:
        continue
      case .tool:
        if !activity.workTimelineHidesChecklistTool(hasChecklist: hasChecklist) { pending.append(activity) }
      case .thought:
        // Empty reasoning has nothing to disclose (T3 `workEntryIsVisibleInGroup`).
        if activity.workTimelineThoughtHasText { pending.append(activity) }
      case .assistant:
        flush()
        guard activity.content?.workTimelineNonempty != nil else { continue }
        entries.append(ConversationWorkTimelineEntry(content: .commentary(activity)))
      case .plan where activity.planKind != "proposal":
        // Execution checklists live above the composer. Their revisions and
        // native control calls remain in the capture, without interrupting
        // the chronological commentary/command groups.
        continue
      case .plan, .progress, .activity:
        flush()
        entries.append(ConversationWorkTimelineEntry(content: .activity(activity)))
      }
    }
    flush(endsTimeline: true)
    return entries
  }

  /// The reply text and commentary IDs to display for one assistant message.
  /// `AssistantTranscriptProjection` keeps the latest segment as the reply,
  /// since the last segment may be its final answer. A segment followed by
  /// visible work stays commentary, including after interruption; hidden
  /// checklist mutations never displace the response.
  public static func displayPartition(
    _ transcript: AssistantTranscriptProjection,
    activities: [AgentRunActivity],
    isLive _: Bool
  ) -> (body: String, commentaryIDs: Set<String>) {
    var commentaryIDs = Set(transcript.commentary.map(\.id))
    guard let index = activities.lastIndex(where: { activity in
      guard activity.kind == .assistant, !commentaryIDs.contains(activity.id),
            let segment = activity.content?.workTimelineNonempty else { return false }
      return transcript.body.hasPrefix(segment)
        && transcript.body.dropFirst(segment.count).allSatisfy(\.isWhitespace)
    }), let segment = activities[index].content else {
      return (transcript.body, commentaryIDs)
    }
    let hasChecklist = activities.contains { $0.kind == .plan && $0.planKind != "proposal" }
    let followedByWork = activities[(index + 1)...].contains { activity in
      switch activity.kind {
      case .assistant, .fileChange: false
      case .thought: activity.workTimelineThoughtHasText
      case .tool: !activity.workTimelineHidesChecklistTool(hasChecklist: hasChecklist)
      case .plan: activity.planKind == "proposal"
      case .progress, .activity: true
      }
    }
    guard followedByWork else { return (transcript.body, commentaryIDs) }
    commentaryIDs.insert(activities[index].id)
    return (String(transcript.body.dropFirst(segment.count)), commentaryIDs)
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
  /// Members still pending or running. Providers never settle a thought
  /// without a status, so only such a thought that ends the timeline is live.
  public let activeActivityIDs: Set<String>

  /// `endsTimeline` marks the run's final entry.
  public init(id: String, activities: [AgentRunActivity], endsTimeline: Bool = false) {
    self.id = id
    self.activities = activities
    let tools = activities.filter { $0.kind != .thought }
    isThoughtOnly = tools.isEmpty
    let actions = Set(tools.map(ConversationToolAction.init))
    action = actions.count == 1 ? actions.first : nil
    hasFailure = tools.last?.workTimelineIsFailure ?? false
    summary = Self.summary(activities: activities, tools: tools)
    activeActivityIDs = Set(activities.enumerated().compactMap { index, activity in
      let live = activity.kind == .thought
        ? endsTimeline && index == activities.count - 1
          && (activity.status?.workTimelineNonempty == nil || activity.workTimelineShowsProgress)
        : activity.workTimelineShowsProgress
      return live ? activity.id : nil
    })
  }

  /// Whether a member is still pending or running; see `activeActivityIDs`.
  public func showsProgress(_ activity: AgentRunActivity) -> Bool {
    activeActivityIDs.contains(activity.id)
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
    if let running = activities.last(where: showsProgress) {
      return running.workTimelineLabel(active: true)
    }
    return activities.last?.workTimelineLabel(active: false)
  }

  public var hasActiveActivity: Bool { !activeActivityIDs.isEmpty }

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
    if name.contains("bash") || name.contains("shell") || name == "exec" || name == "execute"
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
  func workTimelineHidesChecklistTool(hasChecklist: Bool) -> Bool {
    hasChecklist && workTimelineIsChecklistTool && !workTimelineIsFailure
  }

  var workTimelineIsChecklistTool: Bool {
    guard kind == .tool else { return false }
    let names = [toolName, title].compactMap { $0?.lowercased() }
    return names.contains { ["update_plan", "update_checklist", "update_todos", "todowrite", "todo_write", "todo_list"].contains($0) }
  }
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
      if let title = workTimelineThoughtTitle { return title }
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

  /// A generic "Thinking" title alone discloses nothing, so it is not text.
  internal var workTimelineThoughtHasText: Bool {
    workTimelineThoughtTitle != nil || detail?.workTimelineNonempty != nil
      || content?.workTimelineNonempty != nil
  }

  private var workTimelineThoughtTitle: String? {
    guard let title = title?.workTimelineSingleLine,
          !["thinking", "thought", "reasoning"].contains(title.lowercased()) else { return nil }
    return title
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
