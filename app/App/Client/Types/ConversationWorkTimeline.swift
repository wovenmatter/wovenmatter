import Foundation

/// Chronological, display-ready projection of one run's work activity.
///
/// The projection is pure and `Sendable`, so a caller can build it once off the
/// main actor from the run's activity records and pass it to the transcript
/// view. Thoughts and commentary remain standalone rows. Only consecutive
/// visible tool calls form a work group; each nonempty thought starts a new
/// phase. Plans, progress, and agent activity also remain standalone rows.
/// File changes are excluded and stay with the changed-files card.
public struct ConversationWorkTimeline: Equatable, Sendable {
  public let entries: [ConversationWorkTimelineEntry]

  public var hasVisibleActivities: Bool { !entries.isEmpty }

  /// Active work already supplies an indicator. Otherwise an empty timeline,
  /// commentary, or settled tools need a quiet waiting state while the run lives.
  public var needsThinkingIndicator: Bool {
    if entries.contains(where: { entry in
      switch entry.content {
      case .group(let group): group.hasActiveActivity
      case .activity(let activity): activity.workTimelineShowsProgress
      case .commentary: false
      }
    }) { return false }
    guard let last = entries.last else { return true }
    if case .group = last.content { return true }
    if case .activity(let activity) = last.content, activity.kind == .thought { return false }
    return true
  }

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
      versions[update.id, default: Hasher()].combine(update.detailStamp)
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
      // One activity can comprise several trace records. Corrections or
      // deletion of any contributor must invalidate its cached full detail.
      let version = versions[id] ?? Hasher()
      return value.merging(AgentRunActivity(
        id: id, kind: value.kind, detailStamp: Int64(version.finalize())
      ))
    }
  }

  static func entries(for activities: [AgentRunActivity], hasChecklist: Bool) -> [ConversationWorkTimelineEntry] {
    var entries: [ConversationWorkTimelineEntry] = []
    var pending: [AgentRunActivity] = []
    var renderedPages: Set<String> = []
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
        // Revisions have already merged by ID. A new supplied thought is a
        // visible phase boundary. A thought without text still shows that
        // the agent thought, but never splits tools or repeats one before it.
        if !activity.workTimelineThoughtHasText {
          if !pending.isEmpty { continue }
          if case .activity(let prior) = entries.last?.content, prior.kind == .thought,
             !prior.workTimelineThoughtHasText { continue }
        }
        flush()
        entries.append(ConversationWorkTimelineEntry(content: .activity(activity)))
      case .assistant:
        guard activity.content?.workTimelineNonempty != nil else { continue }
        flush()
        entries.append(ConversationWorkTimelineEntry(content: .commentary(activity)))
      case .plan where activity.planKind != "proposal":
        // Execution checklists live above the composer. Their revisions and
        // native control calls remain in the capture, without interrupting
        // the chronological commentary/command groups.
        continue
      case .plan, .progress, .activity:
        if let reference = activity.htmlRender, !renderedPages.insert(reference.id).inserted { continue }
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
    activities: [AgentRunActivity]
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
      isVisibleWork(activity, hasChecklist: hasChecklist)
    }
    guard followedByWork else { return (transcript.body, commentaryIDs) }
    commentaryIDs.insert(activities[index].id)
    return (String(transcript.body.dropFirst(segment.count)), commentaryIDs)
  }

  /// The same visibility rule governs text placement on desktop and mobile.
  /// Background checklist revisions and file cards cannot turn a final answer
  /// into commentary hidden inside the work disclosure.
  public static func isVisibleWork(_ activity: AgentRunActivity, hasChecklist: Bool) -> Bool {
    switch activity.kind {
    case .assistant, .fileChange: false
    case .thought: activity.workTimelineThoughtHasText
    case .tool: !activity.workTimelineHidesChecklistTool(hasChecklist: hasChecklist)
    case .plan: activity.planKind == "proposal"
    case .progress, .activity: true
    }
  }
}

/// A turn's work folds behind its elapsed header, as T3 Code's "Worked for"
/// fold does. It streams open while the turn runs and folds when it ends; the
/// header toggles it either way.
extension ConversationWorkTimeline {
  /// What a folded turn still shows: a proposed plan waits on the reader, and
  /// an inline page is part of the reply rather than a record of the work.
  var entriesOutsideFold: [ConversationWorkTimelineEntry] {
    entries.filter(\.staysOutsideFold)
  }

  /// Whether a fold would hide anything at all.
  var hasFoldableEntries: Bool {
    entries.contains { !$0.staysOutsideFold }
  }
}

extension ConversationWorkTimelineEntry {
  var staysOutsideFold: Bool {
    guard case .activity(let activity) = content else { return false }
    return activity.htmlRender != nil || (activity.kind == .plan && activity.planKind == "proposal")
  }
}

public struct ConversationWorkTimelineEntry: Equatable, Identifiable, Sendable {
  public enum Content: Equatable, Sendable {
    /// Frozen assistant commentary preceding later work.
    case commentary(AgentRunActivity)
    /// Consecutive visible tool calls.
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

/// Consecutive tool calls, summarized using at most two action categories,
/// prioritizing commands and edits, with remaining calls counted as other steps.
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
      // Searches read the same in a summary, whatever their subject.
      let classified = ConversationToolAction(tool)
      let action = classified == .search ? .codeSearch : classified
      if members[action] == nil { order.append(action) }
      members[action, default: []].append(tool)
    }
    // Every kind of step, in order, while there are few; past four, the three
    // that matter most and a count of the rest.
    let selected = order.count <= 4 ? order : order.enumerated()
      .sorted { ($0.element.summaryPriority, $0.offset) < ($1.element.summaryPriority, $1.offset) }
      .prefix(3)
      .sorted { $0.offset < $1.offset }
      .map(\.element)
    var labels = selected.map { action in
      action.summary(count: action.summaryCount(members[action] ?? []))
    }
    let remaining = tools.count - selected.reduce(0) { $0 + (members[$1]?.count ?? 0) }
    if remaining > 0 {
      labels.append("\(remaining) other \(remaining == 1 ? "step" : "steps")")
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
  /// A script that calls tools (code mode).
  case code
  case read
  case edit
  case codeSearch
  /// A search whose subject the event does not name.
  case search
  /// Listing a folder's files.
  case list
  /// Woven's visual reply tool: publishing one in the chat.
  case visual
  /// Checking a visual reply before publishing it.
  case preview
  case webSearch
  case webFetch
  case browser
  case computer
  case delegate
  /// The model's question tool: it asked the person something.
  case question
  case other

  public init(_ activity: AgentRunActivity) {
    let name = activity.workTimelineToolIdentity.lowercased()
    let visualCalls = activity.codeCalls.flatMap { calls in
      calls.isEmpty || !calls.allSatisfy({ Self.isVisual($0.name.lowercased()) }) ? nil : calls
    }
    if Self.isVisual(name) || visualCalls != nil {
      // Woven's own visual reply tools, however a harness names or wraps
      // them: a preview stays a preview unless something was published.
      let previews = visualCalls.map { $0.allSatisfy { $0.name.lowercased().hasSuffix("preview_html") } }
        ?? name.hasSuffix("preview_html")
      self = previews ? .preview : .visual
    } else if activity.codeCalls != nil {
      self = .code
    } else if activity.questions != nil {
      self = .question
    } else if let operation = activity.workTimelineOperation {
      // A command or a titled step that does what a file tool does is that.
      switch operation {
      case .search: self = .codeSearch
      case .list: self = .list
      case .read: self = .read
      }
    } else if activity.workTimelineIsCommand {
      self = .command
    } else if name.contains("websearch") || name.contains("web_search") || name.contains("web search") {
      self = .webSearch
    } else if name.contains("browser") {
      self = .browser
    } else if name.contains("computer") {
      self = .computer
    } else if let step = activity.workTimelineInput?["action"] as? [String: Any],
              step["url"] != nil || (step["type"] as? String)?.lowercased().contains("search") == true {
      // A search tool that reports a web step: a query, or a page it opened.
      self = step["url"] != nil ? .webFetch : .webSearch
    } else if name.contains("web") || name.contains("fetch") || name.contains("browse") {
      // A fetch tool given a query rather than a page searched the web.
      let input = activity.workTimelineInput
      self = input?["query"] != nil && input?["url"] == nil ? .webSearch : .webFetch
    } else if name.contains("grep") || name.contains("glob") {
      self = .codeSearch
    } else if name.contains("search") || name.contains("find") {
      // Only a pattern or a path says the search was over files; a tool
      // that only has search in its name (ToolSearch) is a tool of its own.
      let input = activity.workTimelineInput
      self = input?["pattern"] != nil || activity.workTimelineInputPath != nil ? .codeSearch
        : ["search", "find"].contains(name) ? .search : .other
    } else if name.contains("write") || name.contains("edit")
      || name.contains("patch") || !activity.changes.isEmpty {
      self = .edit
    } else if name.contains("read") || name.contains("view") {
      // A folder's listing is not a file read.
      let output = activity.rawOutputJSON?.prefix(200).lowercased() ?? ""
      self = activity.workTimelineInputPath?.hasSuffix("/") == true || output.hasPrefix("read directory")
        || output.hasPrefix("list") ? .list : .read
    } else if name.contains("task") || name.contains("agent") {
      self = .delegate
    } else {
      // A concrete title such as pwd or ls may not name a known action,
      // but ACP still supplies a reliable execution category.
      self = activity.toolName?.lowercased() == "execute" ? .command : .other
    }
  }

  /// `render_html` or `preview_html`, under any harness's prefix.
  static func isVisual(_ name: String) -> Bool {
    name.hasSuffix("render_html") || name.hasSuffix("preview_html")
  }

  var summaryPriority: Int {
    switch self {
    case .command, .code, .edit, .delegate: 0
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
    case .code: "Ran code \(count) \(plural ? "times" : "time")"
    case .read: "Read \(count) \(plural ? "files" : "file")"
    case .edit: "Changed \(count) \(plural ? "files" : "file")"
    case .codeSearch: "Searched \(count) \(plural ? "times" : "time")"
    case .search: "Searched \(count) \(plural ? "times" : "time")"
    case .list: "Listed \(count) \(plural ? "folders" : "folder")"
    case .visual: "Showed \(count) visual \(plural ? "replies" : "reply")"
    case .preview: "Previewed \(count) visual \(plural ? "replies" : "reply")"
    case .webSearch: "Searched the web \(count) \(plural ? "times" : "time")"
    case .webFetch: "Fetched \(count) web \(plural ? "pages" : "page")"
    case .browser: "Used the browser \(count) \(plural ? "times" : "time")"
    case .computer: "Used the computer \(count) \(plural ? "times" : "time")"
    case .delegate: "Delegated \(count) \(plural ? "tasks" : "task")"
    case .question: plural ? "Asked questions \(count) times" : "Asked questions"
    case .other: "Used \(count) \(plural ? "tools" : "tool")"
    }
  }

  func liveLabel(active: Bool) -> String {
    switch self {
    case .command: active ? "Running a command" : "Ran a command"
    case .code: active ? "Running code" : "Ran code"
    case .read: active ? "Reading a file" : "Read a file"
    case .edit: active ? "Editing a file" : "Edited a file"
    case .codeSearch: active ? "Searching files" : "Searched files"
    case .search: active ? "Searching" : "Searched"
    case .list: active ? "Listing files" : "Listed files"
    case .visual: active ? "Showing a visual reply" : "Showed a visual reply"
    case .preview: active ? "Previewing a visual reply" : "Previewed a visual reply"
    case .webSearch: active ? "Searching the web" : "Searched the web"
    case .webFetch: active ? "Fetching a web page" : "Fetched a web page"
    case .browser: active ? "Using the browser" : "Used the browser"
    case .computer: active ? "Using the computer" : "Used the computer"
    case .delegate: active ? "Delegating a task" : "Delegated a task"
    case .question: active ? "Asking a question" : "Asked a question"
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
  /// leading bold heading, else a category phrase.
  func workTimelineLabel(active: Bool, folder: String? = nil) -> String {
    switch kind {
    case .thought:
      // Raw reasoning is never a label: a title or leading heading, else the kind.
      if let title = workTimelineThoughtTitle { return title }
      if let heading = (content ?? detail).flatMap(Self.leadingBoldHeading) { return heading }
      return active ? "Thinking" : "Thought"
    case .tool:
      return workTimelineToolLabel(active: active, folder: folder)
    default:
      return title?.workTimelineSingleLine ?? toolName?.workTimelineSingleLine ?? "Agent activity"
    }
  }

  /// ACP's toolName can be a broad category (not the called tool name).
  /// Prefer its real title when the category would erase that identity.
  var workTimelineToolIdentity: String {
    let name = toolName?.workTimelineSingleLine ?? ""
    let label = title?.workTimelineSingleLine ?? ""
    let generic = ["", "other", "unknown", "tool", "use tool", "using a tool", "used a tool", "execute"]
    if generic.contains(name.lowercased()), !generic.contains(label.lowercased()),
       name.lowercased() != "execute" || !label.contains(" ") { return label }
    return name.isEmpty ? label : name
  }

  /// The tool's input object, when its raw input is one.
  var workTimelineInput: [String: Any]? {
    rawInputJSON.flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  /// The deepest folder that holds every file or folder these tools named,
  /// when they named at least two and it is not near the root.
  static func workTimelineCommonFolder(_ activities: [AgentRunActivity]) -> String? {
    var paths: Set<String> = []
    for activity in activities where activity.kind == .tool {
      switch activity.workTimelineOperation {
      case .search(_, let path?), .list(let path?): paths.insert(path)
      case .read(let path): paths.insert(path)
      default:
        if let path = activity.workTimelineInputPath ?? activity.title?.workTimelineAbsolutePaths.first { paths.insert(path) }
      }
    }
    let absolute = paths.filter { $0.hasPrefix("/") }.map { $0.split(separator: "/").map(String.init) }
    guard absolute.count >= 2, var common = absolute.first else { return nil }
    for parts in absolute.dropFirst() {
      common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
    }
    // A file the others sit beside is not a folder.
    if absolute.contains(where: { $0 == common }), common.last?.contains(".") == true { common.removeLast() }
    // Only a folder close above all of them: paths under it stay short.
    guard common.count >= 3, absolute.allSatisfy({ $0.count - common.count <= 3 }) else { return nil }
    return "/" + common.joined(separator: "/")
  }

  /// A tool that runs a shell command, by its name.
  var workTimelineIsCommand: Bool {
    let name = workTimelineToolIdentity.lowercased()
    return name.contains("bash") || name.contains("shell") || name == "exec" || name == "execute"
      || name.contains("command") || name.contains("terminal")
  }

  /// What a command, or a step a runtime titled in words, did when that is
  /// what a file tool does: search, list, or read one file. Nil when not
  /// plainly so; the row then shows the command itself.
  var workTimelineOperation: ConversationShellOperation? {
    let input = workTimelineInput
    let folder = ["cwd", "workdir"].lazy.compactMap { input?[$0] as? String }.first
    if workTimelineIsCommand || (toolName?.lowercased() == "execute" && codeCalls == nil) {
      guard let command = (input?["command"] as? String) ?? title else { return nil }
      return ConversationShellOperation.recognize(command, folder: folder)
    }
    // "Search for 'x' in docs", "List files in 'docs'", "List files".
    guard let title = title?.workTimelineSingleLine, input?["path"] == nil, input?["file_path"] == nil else { return nil }
    func unquoted(_ text: Substring) -> String {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      return trimmed.count > 1 && trimmed.first == "'" && trimmed.last == "'" ? String(trimmed.dropFirst().dropLast()) : trimmed
    }
    if title.hasPrefix("Search for "), let range = title.range(of: " in ", options: .backwards) {
      let pattern = unquoted(title[title.index(title.startIndex, offsetBy: 11)..<range.lowerBound])
      let path = unquoted(title[range.upperBound...])
      guard !pattern.isEmpty, !path.isEmpty else { return nil }
      return .search(pattern: pattern, path: folder.map { $0 + "/" + path } ?? path)
    }
    if title == "List files" { return .list(path: folder) }
    if title.hasPrefix("List files in ") {
      let path = unquoted(title.dropFirst(14))
      return path.isEmpty ? nil : .list(path: folder.map { $0 + "/" + path } ?? path)
    }
    return nil
  }

  /// The file or folder a tool's input names.
  var workTimelineInputPath: String? {
    let input = workTimelineInput
    return ["file_path", "filePath", "path"].lazy
      .compactMap { (input?[$0] as? String)?.workTimelineSingleLine }.first
  }

  private func workTimelineToolLabel(active: Bool, folder: String?) -> String {
    let generic = ["tool", "use tool", "using a tool", "used a tool", "other", "execute"]
    let label = title?.workTimelineSingleLine
    let input = workTimelineInput
    let action = ConversationToolAction(self)
    let failed = workTimelineIsFailure
    // Paths inside the folder the tool ran in (else the session's) read relative to it.
    let root = ["cwd", "workdir"].lazy.compactMap { input?[$0] as? String }.first ?? folder
    // A command its runtime titled with it reads as its own text, without the
    // folder plumbing around it. A runtime may cut a long command short to
    // title it: show the whole command, which the row truncates in the
    // middle, keeping its real end.
    if action == .command, let label, let command = (input?["command"] as? String)?.workTimelineSingleLine,
       command.hasPrefix(label) {
      return command.workTimelineDisplayCommand(root: root).workTimelineFirstSegment
    }
    if action == .visual || action == .preview {
      // One plain label in every harness: what it showed, or previewed.
      let arguments = (input?["arguments"] as? [String: Any]) ?? input
      let name = (arguments?["title"] as? String)?.workTimelineSingleLine.map { "\u{201C}\($0)\u{201D}" }
      let verb = action == .preview ? (failed ? "Failed to preview" : active ? "Previewing" : "Previewed")
        : (failed ? "Failed to show" : active ? "Showing" : "Showed")
      return "\(verb) \(name ?? "a visual reply")"
    }
    // A command or step that does what a file tool does reads the same way.
    if let operation = workTimelineOperation {
      switch operation {
      case .search(let pattern, let path):
        return "\(failed ? "Failed to search" : active ? "Searching" : "Searched")"
          + " for \u{201C}\(String(pattern.prefix(60)))\u{201D}" + (path.map { " in " + $0.workTimelineShortPath(root: root) } ?? "")
      case .list(let path):
        return "\(failed ? "Failed to list" : active ? "Listing" : "Listed") "
          + (path.map { $0.workTimelineShortPath(root: root) } ?? "files")
      case .read(let path):
        return "\(failed ? "Failed to read" : active ? "Reading" : "Read") \(path.workTimelineShortPath(root: root))"
      }
    }
    // A file tool reads as its verb and a short path: the input's path, else
    // an absolute path in the title.
    if [.read, .list, .edit, .codeSearch].contains(action) {
      let path = workTimelineInputPath ?? label.flatMap { title in
        title.workTimelineAbsolutePaths.count == 1 ? title.workTimelineAbsolutePaths.first : nil
      }
      if let path {
        let place = path.workTimelineShortPath(root: root)
        switch action {
        case .list: return "\(failed ? "Failed to list" : active ? "Listing" : "Listed") \(place)"
        case .read: return "\(failed ? "Failed to read" : active ? "Reading" : "Read") \(place)"
        case .edit: return "\(failed ? "Failed to edit" : active ? "Editing" : "Edited") \(place)"
        default:
          let pattern = (input?["pattern"] as? String)?.workTimelineSingleLine
          return "\(failed ? "Failed to search" : active ? "Searching" : "Searched")"
            + (pattern.map { " for \u{201C}\(String($0.prefix(60)))\u{201D} in" } ?? "") + " \(place)"
        }
      }
    }
    // Keep a provider's descriptive title; bare function names gain readable
    // action labels below. A generic title must not mask a real tool name.
    if let label, label.contains(" "), !generic.contains(label.lowercased()) {
      return action == .command ? label.workTimelineDisplayCommand(root: root).workTimelineFirstSegment : label
    }
    func argument(_ key: String) -> String? {
      (input?[key] as? String)?.workTimelineSingleLine.map { String($0.prefix(120)) }
    }
    switch action {
    case .command:
      // Show the program, not command arguments that can contain credentials.
      let program = argument("command")?.split(separator: " ").first.map(String.init)
      let name = program.flatMap { token in
        token.contains("=") || token.contains("$") ? nil : URL(fileURLWithPath: token).lastPathComponent
      }
      let identity = workTimelineToolIdentity
      let fallback = ["", "execute", "exec", "command", "tool"].contains(identity.lowercased()) ? "command" : identity
      return "\(failed ? "Failed" : active ? "Running" : "Ran") \(name ?? fallback)"
    case .webSearch:
      let query = argument("query")
      return "\(failed ? "Failed web search" : active ? "Searching the web" : "Searched the web")"
        + (query.map { ": " + $0 } ?? "")
    case .browser:
      let operation = argument("action")?.replacingOccurrences(of: "_", with: " ")
      let host = argument("url").flatMap { URL(string: $0)?.host }
      if operation == nil && host == nil { return failed ? "Browser failed" : action.liveLabel(active: active) }
      return (failed ? "Browser failed" : "Browser")
        + (operation.map { ": " + $0 } ?? "") + (host.map { " " + $0 } ?? "")
    case .other, .search:
      let identity = workTimelineToolIdentity
      if !identity.isEmpty, !generic.contains(identity.lowercased()),
         action == .other || !["search", "find"].contains(identity.lowercased()) {
        return "\(failed ? "Failed" : active ? "Using" : "Used") \(identity)"
      }
      return action.liveLabel(active: active)
    default:
      return action.liveLabel(active: active)
    }
  }

  /// A generic "Thinking" title alone discloses nothing, so it is not text.
  internal var workTimelineThoughtHasText: Bool {
    workTimelineThoughtTitle != nil || detail?.workTimelineNonempty != nil
      || content?.workTimelineNonempty != nil
  }

  var workTimelineThoughtTitle: String? {
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

extension String {
  private static let workTimelinePathPattern = try! NSRegularExpression(
    pattern: #"'(/[^']+)'|"(/[^"]+)"|(?<![\w/.:~$@=-])(/[^\s'";|&()<>]+)"#)
  private static let workTimelineLeadingCD = try! NSRegularExpression(
    pattern: #"^cd\s+('[^']*'|"[^"]*"|[^\s;&]+)\s*(&&|;)\s*"#)
  private static let workTimelineGitFolder = try! NSRegularExpression(
    pattern: #"\bgit\s+-C\s+('[^']*'|"[^"]*"|\S+)"#)

  /// Absolute paths in the text, quoted or bare.
  var workTimelineAbsolutePaths: [String] {
    let text = self as NSString
    return Self.workTimelinePathPattern.matches(in: self, range: NSRange(location: 0, length: text.length))
      .compactMap { match in
        (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
          .map { text.substring(with: $0) }
      }
  }

  /// A path relative to `root` when it is inside it, else its last two
  /// components.
  func workTimelineShortPath(root: String? = nil) -> String {
    let parts = split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return self }
    if let root {
      let base = root.split(separator: "/").map(String.init)
      if parts.count >= base.count, Array(parts.prefix(base.count)) == base {
        // The folder itself is its name.
        return parts.count == base.count ? parts[parts.count - 1] : parts.dropFirst(base.count).joined(separator: "/")
      }
    }
    // A parent that is an opaque identifier (a UUID, a hash) says nothing.
    if parts.count > 1, parts[parts.count - 2].workTimelineIsOpaqueIdentifier { return parts[parts.count - 1] }
    return parts.suffix(2).joined(separator: "/")
  }

  /// A name made of a long run of hexadecimal digits, with or without dashes.
  var workTimelineIsOpaqueIdentifier: Bool {
    let digits = filter { $0 != "-" }
    return digits.count >= 12 && digits.allSatisfy(\.isHexDigit)
  }

  /// A command of several parts shows its first part and an ellipsis:
  /// joined commands, pipelines and here-documents are not flattened into one
  /// middle-cut line.
  var workTimelineFirstSegment: String {
    var quote: Character?
    var index = startIndex
    while index < endIndex {
      let character = self[index]
      let next = self.index(after: index)
      if let open = quote {
        if character == open { quote = nil }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if character == "\\" {
        if next < endIndex { index = self.index(after: next); continue }
      } else if character == ";" || character == "\n" || character == "|"
        || (character == "&" && next < endIndex && self[next] == "&")
        || (character == "<" && next < endIndex && self[next] == "<") {
        let first = self[..<index].trimmingCharacters(in: .whitespaces)
        let rest = self[index...].trimmingCharacters(in: CharacterSet(charactersIn: ";|&<\n ").union(.whitespaces))
        return first.isEmpty || rest.isEmpty ? self : first + " \u{2026}"
      }
      index = next
    }
    return self
  }

  /// A command as a row shows it: no leading `cd <folder> &&`, no
  /// `git -C <folder>`, and other absolute paths relative to `root` when
  /// inside it, else cut to two components.
  func workTimelineDisplayCommand(root: String? = nil) -> String {
    var command = self
    while let match = Self.workTimelineLeadingCD.firstMatch(
      in: command, range: NSRange(location: 0, length: (command as NSString).length)),
      match.range.length < (command as NSString).length {
      command = (command as NSString).replacingCharacters(in: match.range, with: "")
    }
    command = Self.workTimelineGitFolder.stringByReplacingMatches(
      in: command, range: NSRange(location: 0, length: (command as NSString).length), withTemplate: "git")
    let text = command as NSString
    var result = command
    for match in Self.workTimelinePathPattern.matches(
      in: command, range: NSRange(location: 0, length: text.length)).reversed() {
      guard let range = (1...3).lazy.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
      let path = text.substring(with: range)
      let short = path.workTimelineShortPath(root: root)
      // A path already this short (`/dev/null`) stays as written.
      guard short != String(path.drop { $0 == "/" }) else { continue }
      let replacement = short.contains(" ") && range != match.range ? text.substring(with: match.range)
        .replacingOccurrences(of: path, with: short) : short
      result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    return result
  }
}
