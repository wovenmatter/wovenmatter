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

/// Consecutive tool calls, summarized by naming each kind of step they took.
public struct ConversationWorkGroup: Equatable, Identifiable, Sendable {
  public let id: String
  public let activities: [AgentRunActivity]
  /// Settled summary, such as "Ran 3 commands and read 2 files".
  public let summary: String
  /// The single action shared by every tool call, for the summary icon.
  public let action: ConversationToolAction?
  public let isThoughtOnly: Bool
  /// A tool call in it failed, as its own row said.
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
    let actions = Set(tools.map { ConversationToolAction($0) })
    action = actions.count == 1 ? actions.first : nil
    hasFailure = tools.contains(where: \.workTimelineIsFailure)
    // Through the same redaction as the rows it sums up.
    summary = Self.summary(activities: activities, tools: tools).workTimelineRedactingCredentials
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
    sentence(summaryParts(activities: activities, tools: tools).enumerated().map { index, part in
      index == 0 || part.startsWithName ? part.sentence : part.sentence.prefix(1).lowercased() + part.sentence.dropFirst()
    })
  }

  /// The facts of `summary` as short count-first parts, for a column too
  /// narrow for the sentence: "2 files changed · 3 previews · ToolSearch".
  public var compactSummary: String {
    Self.summaryParts(activities: activities, tools: activities.filter { $0.kind != .thought })
      .map(\.compact).joined(separator: " · ").workTimelineRedactingCredentials
  }

  /// One fact of a summary, as the sentence words it and in compact form.
  struct SummaryPart: Equatable {
    let sentence: String
    let compact: String
    /// It starts with a tool's name, which keeps its case mid-sentence.
    var startsWithName = false
  }

  /// Every kind of step, in the order it first ran, in the rows' words.
  /// Files are counted once however often they were touched. Failures stay
  /// with the kind that failed: a verb that claims the outcome (read,
  /// changed, fetched) counts only what succeeded, and the rest apart ("1
  /// read failed"); any other verb counts every call and says how many
  /// failed ("Ran 2 commands, 1 failed", or "ran 2 commands (1 failed)"
  /// beside other kinds), or that all did ("2 commands failed").
  static func summaryParts(activities: [AgentRunActivity], tools: [AgentRunActivity]) -> [SummaryPart] {
    if tools.isEmpty {
      let label = activities.count == 1 ? activities[0].workTimelineLabel(active: false) : "Thought (×\(activities.count))"
      return [SummaryPart(sentence: label, compact: label)]
    }
    // A harness's helper is a kind of its own, beside the action it falls under.
    struct Kind: Hashable { let action: ConversationToolAction; let helper: WorkTimelineHelper.Kind? }
    var kindOrder: [Kind] = []
    var members: [Kind: [AgentRunActivity]] = [:]
    for tool in tools {
      let kind = Kind(action: ConversationToolAction(tool), helper: tool.workTimelineHelper?.kind)
      if members[kind] == nil { kindOrder.append(kind) }
      members[kind, default: []].append(tool)
    }
    let order = kindOrder.map(\.action)
    // Two kinds of search side by side are each named, so neither reads as
    // a repeat of the other.
    let searches: Set<ConversationToolAction> = [.webSearch, .codeSearch, .search]
    let namesSearches = Set(order).intersection(searches).count > 1
    // Each kind's facts, with how many of its calls failed where its verb
    // counts them all; the note is worded once the number of kinds is known.
    let kinds = kindOrder.map { kind -> (parts: [SummaryPart], failed: Int) in
      let action = kind.action
      let all = members[kind] ?? []
      let names = all.map(\.workTimelineToolIdentity).reduce(into: [String]()) { names, name in
        if !name.isEmpty, !names.contains(name) { names.append(name) }
      }
      let failures = all.filter(\.workTimelineIsFailure).count
      if let helper = kind.helper {
        if failures == all.count {
          let text = "\(failures) \(helper.noun(count: failures)) failed"
          return ([SummaryPart(sentence: text, compact: text)], 0)
        }
        let one = all.count == 1 ? all[0].workTimelineHelper : nil
        return ([SummaryPart(sentence: one?.label(active: false, failed: false) ?? helper.summary(count: all.count),
                             compact: one?.compact ?? "\(all.count) \(helper.noun(count: all.count))")], failures)
      }
      // One or two tools its rows showed by a plain name are named; a step
      // whose row is a phrase is counted with the rest, never quoted.
      if action == .other, (1...2).contains(names.count), all.allSatisfy({ $0.workTimelineTitlePhrase == nil }),
         names.allSatisfy({ !$0.contains(" ") }) {
        let several = names.count == 1 && all.count > 1
        if failures == all.count {
          let text = names.joined(separator: " and ") + " failed" + (several ? " \(all.count) times" : "")
          return ([SummaryPart(sentence: text, compact: text, startsWithName: true)], 0)
        }
        return ([SummaryPart(
          sentence: "Used " + names.joined(separator: " and ") + (several ? " \(all.count) times" : ""),
          compact: several ? "\(all.count)× \(names[0])" : names.joined(separator: " · "))], failures)
      }
      if !action.claimsOutcome {
        if failures > 0, failures == all.count {
          let text = "\(failures) \(action.failureNoun(count: failures)) failed"
          return ([SummaryPart(sentence: text, compact: text)], 0)
        }
        let count = action.summaryCount(all)
        let words = all.count == 1 ? action.single(all[0]) : nil
        return ([SummaryPart(sentence: words ?? action.summary(count: count, namingSearch: namesSearches),
                             compact: action.compactSummary(count: count, namingSearch: namesSearches))], failures)
      }
      let done = all.filter { !$0.workTimelineIsFailure }
      var parts: [SummaryPart] = []
      if !done.isEmpty {
        let count = action.summaryCount(done)
        parts.append(SummaryPart(
          sentence: action.summary(count: count, namingSearch: namesSearches),
          compact: action.compactSummary(count: count, namingSearch: namesSearches)))
      }
      if failures > 0 {
        let text = "\(failures) \(action.failureNoun(count: failures)) failed"
        parts.append(SummaryPart(sentence: text, compact: text))
      }
      return (parts, 0)
    }
    let alone = kinds.count == 1
    return kinds.flatMap { kind -> [SummaryPart] in
      guard kind.failed > 0, let part = kind.parts.first else { return kind.parts }
      let noted = alone && kind.parts.count == 1
        ? SummaryPart(sentence: part.sentence + ", \(kind.failed) failed", compact: part.compact + " · \(kind.failed) failed",
                      startsWithName: part.startsWithName)
        : SummaryPart(sentence: part.sentence + " (\(kind.failed) failed)", compact: part.compact + " (\(kind.failed) failed)",
                      startsWithName: part.startsWithName)
      return [noted] + kind.parts.dropFirst()
    }
  }

  /// Parts, each cased for its place, as one sentence: "Read 2 files,
  /// changed 1 file, and ran 3 commands".
  static func sentence(_ sentence: [String]) -> String {
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
  /// Finding text in a web page (Codex's find in page).
  case findInPage
  case browser
  case computer
  case delegate
  /// The model's question tool: it asked the person something.
  case question
  case other

  /// `readsOutput` false classifies by the tool and its input alone, as a
  /// run's path anchor must, since output may come later.
  public init(_ activity: AgentRunActivity, readsOutput: Bool = true) {
    let name = activity.workTimelineToolIdentity.lowercased()
    if let visual = Self.wovenVisual(activity) {
      self = visual
    } else if activity.codeCalls != nil {
      self = .code
    } else if activity.questions != nil {
      self = .question
    } else if activity.workTimelineIsDelegation {
      self = .delegate
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
    } else if (activity.workTimelineInput?["action"] as? [String: Any])?["type"] as? String == "findInPage" {
      // Codex's search inside a page, told by the step it reports before
      // any page it names.
      self = .findInPage
    } else if let step = activity.workTimelineInput?["action"] as? [String: Any],
              step["url"] != nil || (step["type"] as? String)?.lowercased().contains("search") == true {
      // A search tool that reports a web step: a query, or a page it opened.
      self = step["url"] != nil ? .webFetch : .webSearch
    } else if (activity.workTimelineInput?["type"] as? String)?.lowercased() == "websearch"
      || activity.title?.workTimelineSingleLine?.lowercased() == "web search" {
      // A step its runtime calls a web search, without saying which (Codex's
      // "Web search" rows), is one, as its row says.
      self = .webSearch
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
    } else if ["list", "ls", "list_directory", "list_dir", "listdir"].contains(name) {
      // OpenCode's `list`, and the like: a folder's listing by the tool's own name.
      self = .list
    } else if name.contains("read") || name.contains("view") {
      // A folder's listing is not a file read.
      self = readsOutput && activity.workTimelineReadsFolder ? .list : .read
    } else if name.contains("task") || name.contains("agent") {
      self = .delegate
    } else {
      // A concrete title such as pwd or ls may not name a known action,
      // but ACP still supplies a reliable execution category.
      self = activity.toolName?.lowercased() == "execute" ? .command : .other
    }
  }

  /// Woven's own `render_html` or `preview_html`, by the name or title a
  /// runtime gives it: alone, or after the `woven` server and its separator,
  /// as the server recognises it. Another server's tool of that name is not.
  private static let wovenVisualName = try! NSRegularExpression(
    pattern: #"^(?:(?:.*[^a-z0-9])?woven(?:__|[_./:]\s*|\s+))?(render_html|preview_html)$"#)

  static func wovenVisualTool(_ name: String) -> ConversationToolAction? {
    let name = name.trimmingCharacters(in: .whitespaces).lowercased()
    let range = NSRange(location: 0, length: (name as NSString).length)
    guard let match = wovenVisualName.firstMatch(in: name, range: range) else { return nil }
    return (name as NSString).substring(with: match.range(at: 1)) == "preview_html" ? .preview : .visual
  }

  /// Showing a visual reply, or checking one: a Woven visual tool, or a
  /// script that called only those. A script claims to have shown one only
  /// when a call of it was shown in the chat (or still runs); one whose
  /// publication failed is a script that ran.
  static func wovenVisual(_ activity: AgentRunActivity) -> ConversationToolAction? {
    if let calls = activity.codeCalls {
      let named = calls.filter { $0.status != nil }
      let kinds = named.map { wovenVisualTool($0.name) }
      guard !named.isEmpty, !kinds.contains(nil) else { return nil }
      if zip(named, kinds).contains(where: { $1 == .visual && [.shownInChat, .running].contains($0.status) }) {
        return .visual
      }
      return kinds.allSatisfy { $0 == .preview } ? .preview : nil
    }
    return [activity.toolName, activity.title].lazy.compactMap { $0.flatMap(wovenVisualTool) }.first
  }

  /// Whether the summary's verb says the step succeeded (read, changed,
  /// showed), so failed members are counted apart.
  var claimsOutcome: Bool {
    [.read, .edit, .list, .visual, .preview, .webFetch].contains(self)
  }

  /// What failed, as "2 edits failed" counts it.
  func failureNoun(count: Int) -> String {
    let plural = count != 1
    return switch self {
    case .command: plural ? "commands" : "command"
    case .code: plural ? "scripts" : "script"
    case .read: plural ? "reads" : "read"
    case .edit: plural ? "edits" : "edit"
    case .codeSearch, .search: plural ? "searches" : "search"
    case .list: plural ? "listings" : "listing"
    case .visual: plural ? "visual replies" : "visual reply"
    case .preview: plural ? "previews" : "preview"
    case .webSearch: plural ? "web searches" : "web search"
    case .webFetch: plural ? "fetches" : "fetch"
    case .findInPage: plural ? "finds" : "find"
    case .browser: plural ? "browser steps" : "browser step"
    case .computer: plural ? "computer steps" : "computer step"
    case .delegate: plural ? "tasks" : "task"
    case .question: plural ? "questions" : "question"
    case .other: plural ? "tools" : "tool"
    }
  }

  /// Reads, edits and listings count distinct files, plus each one that
  /// names none; every other step counts its calls.
  func summaryCount(_ activities: [AgentRunActivity]) -> Int {
    guard [.read, .edit, .list].contains(self) else { return activities.count }
    var paths: Set<String> = []
    var unnamed = 0
    for activity in activities {
      let named = activity.workTimelineSubjectPaths
      if named.isEmpty { unnamed += 1 } else { paths.formUnion(named) }
    }
    return paths.count + unnamed
  }

  public func summary(count: Int) -> String { summary(count: count, namingSearch: false) }

  /// `namingSearch` names which kind a search was, for a summary with two.
  /// Two or more of a kind are counted by a noun ("Ran 3 searches"); one is
  /// said in words, never "1 time" (`single` says it in its own words).
  func summary(count: Int, namingSearch: Bool) -> String {
    let plural = count != 1
    return switch self {
    case .command: "Ran \(count) \(plural ? "commands" : "command")"
    case .code: plural ? "Ran \(count) scripts" : "Ran code"
    case .read: "Read \(count) \(plural ? "files" : "file")"
    case .edit: "Changed \(count) \(plural ? "files" : "file")"
    case .codeSearch: plural ? "Ran \(count) \(namingSearch ? "file " : "")searches" : namingSearch ? "Searched files" : "Searched"
    case .search: plural ? "Ran \(count) \(namingSearch ? "other " : "")searches" : namingSearch ? "Ran another search" : "Searched"
    case .list: "Listed \(count) \(plural ? "folders" : "folder")"
    case .visual: "Showed \(count) visual \(plural ? "replies" : "reply")"
    case .preview: plural ? "Ran \(count) previews" : "Previewed a visual reply"
    case .webSearch: plural ? "Ran \(count) web searches" : "Searched the web"
    case .webFetch: "Fetched \(count) web \(plural ? "pages" : "page")"
    case .findInPage: "Found text in \(count) \(plural ? "pages" : "page")"
    case .browser: plural ? "Took \(count) browser steps" : "Used the browser"
    case .computer: plural ? "Took \(count) computer steps" : "Used the computer"
    case .delegate: "Delegated \(count) \(plural ? "tasks" : "task")"
    case .question: plural ? "Asked questions \(count) times" : "Asked questions"
    case .other: "Used \(count) \(plural ? "tools" : "tool")"
    }
  }

  /// One step of this kind in its own words, where they are short: what it
  /// searched ("Searched palette.md", "Searched the web for “sqlite”"). Nil
  /// leaves it to `summary`.
  func single(_ activity: AgentRunActivity) -> String? {
    let input = activity.workTimelineInput
    switch self {
    case .codeSearch:
      if let path = activity.workTimelineSubjectPaths.first { return "Searched " + (path as NSString).lastPathComponent }
      guard let pattern = (input?["pattern"] as? String)?.workTimelineSingleLine, pattern.count <= 30 else { return nil }
      return "Searched for \u{201C}\(pattern)\u{201D}"
    case .webSearch:
      guard let query = activity.workTimelineWebQuery, query.count <= 40 else { return nil }
      return "Searched the web for \u{201C}\(query)\u{201D}"
    case .delegate:
      return activity.workTimelineDelegatedTask.map { "Delegated \u{201C}\($0)\u{201D}" }
    default:
      return nil
    }
  }

  /// The same count as `summary`, count first and short.
  func compactSummary(count: Int, namingSearch: Bool) -> String {
    let plural = count != 1
    let searches = plural ? "searches" : "search"
    return switch self {
    case .command: "\(count) \(plural ? "commands" : "command")"
    case .code: "\(count) \(plural ? "scripts" : "script")"
    case .read: "\(count) \(plural ? "files" : "file") read"
    case .edit: "\(count) \(plural ? "files" : "file") changed"
    case .codeSearch: "\(count) \(namingSearch ? "file " : "")\(searches)"
    case .search: "\(count) \(namingSearch ? "other " : "")\(searches)"
    case .list: "\(count) \(plural ? "folders" : "folder") listed"
    case .visual: "\(count) visual \(plural ? "replies" : "reply")"
    case .preview: "\(count) \(plural ? "previews" : "preview")"
    case .webSearch: "\(count) web \(searches)"
    case .webFetch: "\(count) \(plural ? "pages" : "page") fetched"
    case .findInPage: "\(count) \(plural ? "finds" : "find")"
    case .browser: "\(count) browser \(plural ? "steps" : "step")"
    case .computer: "\(count) computer \(plural ? "steps" : "step")"
    case .delegate: "\(count) \(plural ? "tasks" : "task")"
    case .question: plural ? "\(count)× questions" : "questions"
    case .other: "\(count) \(plural ? "tools" : "tool")"
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
    case .findInPage: active ? "Finding in page" : "Found in page"
    case .browser: active ? "Using the browser" : "Used the browser"
    case .computer: active ? "Using the computer" : "Used the computer"
    case .delegate: active ? "Delegating a task" : "Delegated a task"
    case .question: active ? "Asking a question" : "Asked a question"
    case .other: active ? "Using a tool" : "Used a tool"
    }
  }
}

public extension AgentRunActivity {
  /// A checklist update while the checklist shows, and a subagent handing
  /// its report back (Claude Code's `SubagentHandback`, which the
  /// delegation's own row stands for), draw no row.
  func workTimelineHidesChecklistTool(hasChecklist: Bool) -> Bool {
    if kind == .tool, workTimelineToolIdentity == "SubagentHandback", !workTimelineIsFailure { return true }
    return hasChecklist && workTimelineIsChecklistTool && !workTimelineIsFailure
  }

  /// A call that delegates a task to a subagent: Claude Code's Task tool,
  /// which sends a `prompt` and a short `description`, and which its ACP
  /// adapter reports as a call of kind `think` whose input streams in: `{}`
  /// first, then `{description}`, then the rest, the prompt last. (Codex's
  /// guardian review is also of kind `think`, but always comes with its whole
  /// input, a review with no description; Claude's web fetch sends a prompt
  /// and a URL, no description.)
  /// Which call that is depends on the session's runtime, so it is decided
  /// where that is known (`delegates`).
  var workTimelineIsDelegation: Bool {
    kind == .tool && delegates == true
  }

  /// The name of the task it delegated, once known: its input's
  /// `description`, or the adapter's title, which is that description (or
  /// "Task" before it is known).
  var workTimelineDelegatedTask: String? {
    guard workTimelineIsDelegation else { return nil }
    if let name = (workTimelineInput?["description"] as? String)?.workTimelineSingleLine { return name }
    guard toolName == "think", let title = title?.workTimelineSingleLine, title != "Task" else { return nil }
    return title
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
      // A row's words never carry a credential its call was given.
      return workTimelineToolLabel(active: active, folder: folder).workTimelineRedactingCredentials
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

  /// The tool's input object, when its raw input is one. It is decoded once
  /// per activity and input, since the timeline is rebuilt on every update.
  var workTimelineInput: [String: Any]? {
    guard let raw = rawInputJSON else { return nil }
    return WorkTimelineMemo.shared.input(id: id, raw: raw)
  }

  /// The folder a turn's paths read relative to when nothing says where its
  /// tools ran: decided by the first path a tool named, and then kept for
  /// the run (keyed by its first activity), so a row's short path never
  /// changes once shown, even when an earlier tool's input arrives later. A
  /// folder that the tool and its input say it lists or searches, or a path
  /// that by itself names a folder, is the anchor itself, and any other
  /// path's anchor is the folder it is in; the tool's output, which may come
  /// later, never counts, so a read that turns out to list a folder anchors
  /// as its path reads.
  static func workTimelineAnchorFolder(_ activities: [AgentRunActivity]) -> String? {
    guard let run = activities.first?.id else { return nil }
    return WorkTimelineMemo.shared.anchor(run: run) { workTimelineFirstAnchor(activities) }
  }

  /// The anchor the first path a tool named gives (`.some(nil)` when that
  /// path anchors nothing), or nil while no tool has named one.
  private static func workTimelineFirstAnchor(_ activities: [AgentRunActivity]) -> String?? {
    for activity in activities where activity.kind == .tool {
      let folder: String?
      switch activity.workTimelineOperation {
      case .list(let path?), .search(_, let path?): folder = path
      case .read(let path): folder = (path as NSString).deletingLastPathComponent
      default:
        guard let path = activity.workTimelineInputPath ?? activity.title?.workTimelineAbsolutePaths.first else { continue }
        let lists = ConversationToolAction(activity, readsOutput: false) == .list
        folder = lists || path.workTimelineNamesFolder ? path : (path as NSString).deletingLastPathComponent
      }
      // Only an absolute folder well below the root anchors anything.
      if let folder, folder.hasPrefix("/"), folder.split(separator: "/").count >= 3 { return .some(folder) }
      return .some(nil)
    }
    return nil
  }

  /// A read tool that read a folder: its input path ends in `/`, or its
  /// output opens by saying it read that very directory (OpenCode's
  /// `Read directory <path>, entries …`), never because of what a file says.
  var workTimelineReadsFolder: Bool {
    guard let path = workTimelineInputPath else { return false }
    if path.hasSuffix("/") { return true }
    guard let output = rawOutputJSON, output.hasPrefix("Read directory " + path) else { return false }
    let rest = output.dropFirst(("Read directory " + path).count)
    return rest.isEmpty || rest.first == "," || rest.first?.isNewline == true
  }

  /// The files a step names, for counting each once: a change's paths,
  /// else its locations, else what it read, listed or searched, else its
  /// input's path, else the one absolute path in its title.
  var workTimelineSubjectPaths: [String] {
    let changed = changes.map(\.path).filter { !$0.isEmpty }
    if !changed.isEmpty { return changed }
    let located = locations.map(\.path).filter { !$0.isEmpty }
    if !located.isEmpty { return located }
    switch workTimelineOperation {
    case .read(let path), .list(let path?), .search(_, let path?): return [path]
    default: break
    }
    if let path = workTimelineInputPath { return [path] }
    let titled = title?.workTimelineAbsolutePaths ?? []
    return titled.count == 1 ? titled : []
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
      // Only a command the row may show says what it did: one the runtime
      // titled the row with.
      guard let command = workTimelineTitledCommand else { return nil }
      return ConversationShellOperation.recognize(command, folder: folder)
    }
    // "List files in 'docs'", "List files". A runtime's own "Search for 'x'
    // in y" is not taken as an operation: its parser can read an option's
    // value as the pattern (`--color never`), and the command is not there
    // to check it against (`workTimelineIsUncheckedSearch`).
    guard let title = title?.workTimelineSingleLine, input?["path"] == nil, input?["file_path"] == nil else { return nil }
    func unquoted(_ text: Substring) -> String {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      return trimmed.count > 1 && trimmed.first == "'" && trimmed.last == "'" ? String(trimmed.dropFirst().dropLast()) : trimmed
    }
    if title == "List files" { return .list(path: folder) }
    if title.hasPrefix("List files in ") {
      let path = unquoted(title.dropFirst(14))
      return path.isEmpty ? nil : .list(path: folder.map { $0 + "/" + path } ?? path)
    }
    return nil
  }

  /// A search a runtime describes only in a title of its own making ("Search
  /// for 'never' in library", Codex's reading of a command it does not
  /// send): what it searched for and where is not certain, so the row says
  /// only that it searched.
  var workTimelineIsUncheckedSearch: Bool {
    guard kind == .tool, rawInputJSON?.workTimelineNonempty == nil, let title = title?.workTimelineSingleLine else { return false }
    return title == "Search" || title.hasPrefix("Search for ") || title.hasPrefix("Search in '")
  }

  /// What a web search looked for, when its input says so for certain: its
  /// `query`, or the one query of Codex's search action.
  var workTimelineWebQuery: String? {
    let input = workTimelineInput
    if let step = input?["action"] as? [String: Any] {
      guard step["type"] as? String == "search" else { return nil }
      if let query = (step["query"] as? String)?.workTimelineSingleLine { return query }
      guard let queries = step["queries"] as? [String], queries.count == 1 else { return nil }
      return queries[0].workTimelineSingleLine
    }
    return (input?["query"] as? String)?.workTimelineSingleLine
  }

  /// The page a fetch opened or a find searched, without its scheme: its
  /// input's `url`, or the one Codex's open-page or find-in-page action names.
  var workTimelineWebPage: String? {
    let input = workTimelineInput
    let step = input?["action"] as? [String: Any]
    if let step, !["openPage", "findInPage"].contains(step["type"] as? String ?? "") { return nil }
    guard let url = ((step?["url"] ?? input?["url"]) as? String)?.workTimelineSingleLine else { return nil }
    // Without its scheme, and without a user and password before the host.
    return url.replacingOccurrences(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"^[^/\s@?#]+@"#, with: "…@", options: .regularExpression)
  }

  /// The file or folder a tool's input names.
  var workTimelineInputPath: String? {
    let input = workTimelineInput
    return ["file_path", "filePath", "path"].lazy
      .compactMap { (input?[$0] as? String)?.workTimelineSingleLine }.first
  }

  /// The command as written, when the runtime titled the row with it: the
  /// whole command, or its start cut short (with or without an ellipsis).
  /// Only such a command may show in the row; a tool's name as the title
  /// ("Bash", "Terminal") leaves only the program to show, since arguments
  /// can carry credentials. Without a command in the input, a title of
  /// several words is the command. A command the runtime ran through a
  /// shell (`/bin/zsh -lc "…"`, which Codex titles as the quoted inner
  /// command) is the inner command.
  var workTimelineTitledCommand: String? {
    guard let given = workTimelineInput?["command"] as? String else {
      return title?.workTimelineSingleLine?.contains(" ") == true ? title : nil
    }
    guard let title = title?.workTimelineSingleLine else { return nil }
    func titled(_ command: String, _ title: String) -> String? {
      guard let line = command.workTimelineSingleLine else { return nil }
      if line == title { return command }
      var label = title
      for mark in ["\u{2026}", "..."] where label.hasSuffix(mark) {
        label = String(label.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
      }
      return label.contains(" ") && line.hasPrefix(label) ? command : nil
    }
    if let command = titled(given, title) { return command }
    guard let script = given.workTimelineShellScript else { return nil }
    let unquoted = title.count > 1 && title.hasPrefix("\"") && title.hasSuffix("\"") ? String(title.dropFirst().dropLast()) : title
    return titled(script, unquoted)
  }

  /// The row's label is the command line itself, not words about a step:
  /// the label code and this flag both read `workTimelineCommandText`.
  var workTimelineLabelIsCommand: Bool {
    workTimelineCommandText(root: nil) != nil
  }

  /// The command text a command row shows as its label, or nil when its
  /// label is words: the command its runtime titled it with (never a
  /// script's, which reads as the script), or, without one in its input,
  /// its title of several words.
  fileprivate func workTimelineCommandText(root: String?) -> String? {
    guard kind == .tool, ConversationToolAction(self) == .command else { return nil }
    if let command = workTimelineTitledCommand {
      return command.workTimelineScript == nil ? command.workTimelineCommandLine(root: root) : nil
    }
    return workTimelineTitlePhrase.map { (title ?? $0).workTimelineCommandLine(root: root) }
  }

  /// A harness's own helper, named for what it does rather than by its
  /// identifier: Claude Code's ToolSearch looks up the tools it may call,
  /// and its Skill tool loads a skill. Any other tool keeps its own name.
  var workTimelineHelper: WorkTimelineHelper? {
    guard kind == .tool else { return nil }
    let input = workTimelineInput
    if workTimelineToolIdentity == "ToolSearch" {
      guard let query = (input?["query"] as? String)?.workTimelineSingleLine else { return WorkTimelineHelper(kind: .toolLookup) }
      if query.lowercased().hasPrefix("select:") {
        // `select:a,b`: the tools it asked for by name, Woven's and the
        // harness's own by what they do, any other without a server's prefix.
        let names = query.dropFirst(7).split(separator: ",").map { name -> String in
          let name = name.trimmingCharacters(in: .whitespaces)
          switch ConversationToolAction.wovenVisualTool(name) {
          case .visual?: return "the visual reply tool"
          case .preview?: return "the preview tool"
          default: break
          }
          switch name {
          case "WebSearch": return "the web search tool"
          case "WebFetch": return "the web fetch tool"
          default: return name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
          }
        }.filter { !$0.isEmpty }
        return WorkTimelineHelper(kind: .toolLookup, object: (1...2).contains(names.count) ? names.joined(separator: " and ") : nil)
      }
      return WorkTimelineHelper(kind: .toolLookup, object: query.count <= 40 ? "tools for \u{201C}\(query)\u{201D}" : nil)
    }
    let skill = (input?["skill"] as? String)?.workTimelineSingleLine
    if workTimelineToolIdentity == "Skill" && skill == nil
      || skill != nil && (toolName?.lowercased() == "skill" || title?.hasPrefix("Load skill") == true) {
      return WorkTimelineHelper(kind: .skill, object: skill)
    }
    return nil
  }

  /// The runtime's own title when the row shows it as it is, a phrase
  /// ("Load skill: dataviz"), rather than a tool's name; a group's summary
  /// decides the same way. A generic title must not mask a real tool name.
  var workTimelineTitlePhrase: String? {
    guard let label = title?.workTimelineSingleLine, label.contains(" "),
          !Self.workTimelineGenericTitles.contains(label.lowercased()) else { return nil }
    return label
  }

  private static let workTimelineGenericTitles = ["tool", "use tool", "using a tool", "used a tool", "other", "execute"]

  /// The titles Claude Code's adapter gives a call before its input names
  /// anything (a read with no path yet is "Read File").
  private static let workTimelinePlaceholderTitles: Set<String> = [
    "read file", "preparing file…", "preparing file...", "edit", "edit notebook", "write", "find", "grep", "fetch",
    "web search", "terminal", "task", "read", "search", "list",
  ]

  private func workTimelineToolLabel(active: Bool, folder: String?) -> String {
    let generic = Self.workTimelineGenericTitles
    let label = title?.workTimelineSingleLine
    let input = workTimelineInput
    let action = ConversationToolAction(self)
    let failed = workTimelineIsFailure
    // Paths inside the folder the tool ran in (else the session's) read relative to it.
    let root = ["cwd", "workdir"].lazy.compactMap { input?[$0] as? String }.first ?? folder
    // A command its runtime titled with it reads as its own text, without the
    // folder plumbing around it. A runtime may cut a long command short to
    // title it: show the whole command, which the row truncates in the
    // middle, keeping its real end. Any other title keeps the program only.
    if action == .command, let script = workTimelineTitledCommand?.workTimelineScript {
      // Failed as a script run in code mode fails ("Code failed"); when
      // more ran after the script, which step failed is not known, so the
      // row says what ran and the failure stays the command's.
      let done = failed && !script.more ? script.language.prefix(1).uppercased() + script.language.dropFirst() + " script failed"
        : (active ? "Running a " : "Ran a ") + script.language + " script"
      return done + (script.more ? " \u{2026}" : "")
    }
    if let text = workTimelineCommandText(root: root) { return text }
    if let helper = workTimelineHelper { return helper.label(active: active, failed: failed) }
    if workTimelineIsUncheckedSearch { return failed ? "Failed to search files" : active ? "Searching files" : "Searched files" }
    if workTimelineIsDelegation {
      let verb = failed ? "Failed to delegate" : active ? "Delegating" : "Delegated"
      return verb + (workTimelineDelegatedTask.map { " \u{201C}\($0)\u{201D}" } ?? " a task")
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
    // A web search or a page fetch reads the same in every harness, in these
    // words rather than the tool's: what it searched for or which page it
    // opened, when its input says so for certain.
    if action == .webSearch {
      return (failed ? "Failed to search the web" : active ? "Searching the web" : "Searched the web")
        + (workTimelineWebQuery.map { " for \u{201C}\($0)\u{201D}" } ?? "")
    }
    // A find in a page says what it found where, when both are reported.
    if action == .findInPage {
      let pattern = ((input?["action"] as? [String: Any])?["pattern"] as? String)?.workTimelineSingleLine
      guard let pattern, let page = workTimelineWebPage else { return failed ? "Failed to find in page" : action.liveLabel(active: active) }
      return (failed ? "Failed to find" : active ? "Finding" : "Found") + " \u{201C}\(pattern)\u{201D} in \(page)"
    }
    let step = (input?["action"] as? [String: Any])?["type"] as? String
    if action == .webFetch, step == nil || step == "openPage" {
      guard let page = workTimelineWebPage else { return failed ? "Failed to fetch a web page" : action.liveLabel(active: active) }
      return (failed ? "Failed to fetch " : active ? "Fetching " : "Fetched ") + page
    }
    // A title that stands in until the input arrives ("Read File", "Web
    // search") names nothing: the row says what kind of step it is.
    if rawInputJSON?.workTimelineNonempty == nil, let title = label,
       Self.workTimelinePlaceholderTitles.contains(title.lowercased()), action != .other {
      return action.liveLabel(active: active)
    }
    // Keep a provider's descriptive title; bare function names gain readable
    // action labels below.
    if let phrase = workTimelineTitlePhrase {
      return phrase
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
      // Until the command is known the row says only that one runs: the
      // tool's own name ("Terminal", "Bash") says nothing about what runs.
      guard let name else { return failed ? "Failed to run a command" : action.liveLabel(active: active) }
      return "\(failed ? "Failed" : active ? "Running" : "Ran") \(name)"
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

  /// The text with the values of credentials it carries replaced by "…":
  /// authorization and key headers, bearer tokens, `-u user:pass`, options
  /// and assignments named for a token, key, secret or password, and the
  /// user and password in a URL.
  /// Only as much as a row or summary can show is looked at: past that the
  /// text is cut, so no pattern ever reads a long command whole.
  var workTimelineRedactingCredentials: String {
    var text = count > Self.workTimelineShownLength ? String(prefix(Self.workTimelineShownLength)) + "\u{2026}" : self
    for (pattern, template) in Self.workTimelineCredentialPatterns {
      text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    return text
  }

  /// More than a row or a summary ever shows at any width.
  private static let workTimelineShownLength = 1_000

  // A value: quoted whole, or quoted and still open where the text was cut,
  // or up to the next space or quote.
  // A double-quoted value runs past escaped characters (`\"`) to its closing
  // quote, or to the cut.
  private static let workTimelineCredentialValue = #"(?:'[^']*'|'[^']*$|"(?:[^"\\]|\\.)*(?:"|\\?$)|[^\s&'"“”‘’]+)"#
  // A name that is a credential's whole name or ends in one (`GITHUB_TOKEN`,
  // `api_key`, `password`, `--oauth2-bearer`), never a word that merely
  // contains one (`key`, `max-tokens`).
  private static let workTimelineCredentialName =
    #"(?:api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|token|secret|password|passwd|pwd|auth|bearer)"#

  // Each pattern starts at a word or token boundary and inspects a name once.
  // `Basic` and `Bearer` are masked as part of an authorization header's
  // value, never on their own (`echo basic info`).
  private static let workTimelineCredentialPatterns: [(NSRegularExpression, String)] = [
    (#"(?i)\b(authorization|proxy-authorization|x-api-key|api-key|cookie)(\s*:\s*)(?:"(?:[^"\\]|\\.)*(?:"|\\?$)|'[^']*'?|[^'"“”\n]+)"#,
     "$1$2…"),
    (#"(?<!\S)(-u|--user)(\s+|=)(?:'[^':]*:[^']*'?|"(?:[^"\\:]|\\[^:])*\\?:(?:[^"\\]|\\.)*(?:"|\\?$)|[^\s'"]+:[^\s'"]+)"#, "$1$2…"),
    (#"(?i)(?<!\S)(--?(?:[a-z0-9]+-)*"# + workTimelineCredentialName + #")(\s+)(?!-)"# + workTimelineCredentialValue, "$1$2…"),
    (#"(?i)(?<![A-Za-z0-9_.-])((?:[A-Za-z0-9_.-]*[_.-])?"# + workTimelineCredentialName + ")=" + workTimelineCredentialValue, "$1=…"),
    (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@?#]+@"#, "$1…@"),
  ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}

extension String {
  /// Whether a path, by itself, names a folder rather than a file: it ends
  /// in `/`, or its last part has no extension. A read tool's input says no
  /// more until its output arrives (OpenCode's `read` lists a folder it is
  /// given), and a run's anchor must be the same whenever it is decided, so
  /// the anchor reads the path alone. A file without an extension (`Makefile`) then anchors
  /// at itself, and the paths beside it show their last two parts, as they
  /// would with no anchor.
  var workTimelineNamesFolder: Bool {
    hasSuffix("/") || !(split(separator: "/").last ?? "").contains(".")
  }

  private static let workTimelinePathPattern = try! NSRegularExpression(
    pattern: #"'(/[^']+)'|"(/[^"]+)"|(?<![\w/.:~$@=-])(/[^\s'";|&()<>]+)"#)
  private static let workTimelineLeadingCD = try! NSRegularExpression(
    pattern: #"^cd[ \t]+('[^']*'|"[^"]*"|[^\s;&]+)[ \t]*(&&|;|\r?\n)\s*"#)
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
  /// components. A relative path, given where the tool ran, already is
  /// relative to that folder and stays whole.
  func workTimelineShortPath(root: String? = nil) -> String {
    let parts = split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return self }
    if let root {
      if !hasPrefix("/"), !hasPrefix("~") {
        let named = parts.filter { $0 != "." }
        return named.isEmpty ? self : named.joined(separator: "/")
      }
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

  /// A command as its row shows it, on one line: the first line that does
  /// something (not blank, a comment, a shebang or a `set` of shell
  /// options), with the lines it continues onto with a trailing `\`, every
  /// part of it (`a && b | c; d`), without the folder plumbing, then its
  /// whitespace collapsed. " …" stands for what a label leaves out: the
  /// lines after it, such as a here-document's body or the rest of a script.
  func workTimelineCommandLine(root: String? = nil) -> String {
    var lines: [String] = []
    var continued = false
    for line in components(separatedBy: .newlines) {
      if continued, let last = lines.popLast() { lines.append(String(last.dropLast()) + " " + line) } else { lines.append(line) }
      continued = line.hasSuffix("\\")
    }
    let doing = lines.filter { line in
      let text = line.trimmingCharacters(in: .whitespaces)
      return !text.isEmpty && !text.hasPrefix("#") && text.range(of: #"^set(\s+[-+][A-Za-z]+(\s+[a-z]+)?)+$"#, options: .regularExpression) == nil
    }
    guard let first = doing.first else { return workTimelineSingleLine ?? self }
    let shown = first.workTimelineDisplayCommand(root: root).workTimelineSingleLine ?? first
    return doing.count > 1 ? shown + " \u{2026}" : shown
  }

  /// The language of the script a command runs first, and whether lines that
  /// do something follow it: an interpreter fed a here-document alone on the
  /// first line (`python3 - <<'EOF'`, its body, `EOF`, then perhaps more
  /// lines), or given the script inline in one pair of single quotes that
  /// ends the command (`python3 -c '…'`, `node -e '…'`). Anything else is
  /// not certain and gives nil.
  var workTimelineScript: (language: String, more: Bool)? {
    let command = workTimelineDisplayCommand().trimmingCharacters(in: .whitespacesAndNewlines)
    let languages = ["python": "Python", "python3": "Python", "node": "Node.js", "ruby": "Ruby",
                     "bash": "shell", "sh": "shell", "zsh": "shell"]
    let inlineFlag = ["python": "-c", "python3": "-c", "bash": "-c", "sh": "-c", "zsh": "-c", "node": "-e", "ruby": "-e"]
    func match(_ pattern: String, _ text: String) -> [String]? {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
      return (0..<found.numberOfRanges).map { Range(found.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    // Lines as the shell reads them: split at LF alone, so a CR stays in its line.
    let lines = command.components(separatedBy: "\n")
    if let first = lines.first,
       let parts = match(#"^(python3?|node|ruby|bash|sh|zsh)(?: -)? *<<(-?) *(['"]?)([A-Za-z_][A-Za-z0-9_]*)\3$"#, first),
       let language = languages[parts[1]],
       // The terminator is the delimiter alone on its line, after leading
       // tabs only with `<<-`, as the shell reads it.
       let end = lines.indices.dropFirst().first(where: {
         (parts[2] == "-" ? String(lines[$0].drop { $0 == "\t" }) : lines[$0]) == parts[4]
       }) {
      // What runs after the here-document ends, if anything.
      let more = lines[(end + 1)...].contains { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && !text.hasPrefix("#")
      }
      return (language, more)
    }
    if let parts = match(#"^(python3?|node|ruby|bash|sh|zsh) +(-[ce]) +'[^']*'$"#, command), inlineFlag[parts[1]] == parts[2],
       let language = languages[parts[1]] {
      return (language, false)
    }
    return nil
  }

  /// The command a shell is given to run, when that is all this is
  /// (`/bin/zsh -lc "…"`, `bash -c '…'`), as the shell reads its quotes.
  var workTimelineShellScript: String? {
    let shell = #"^(?:/(?:usr/)?bin/)?(?:zsh|bash|sh) +-l?c +"#
    if let range = range(of: shell + #""((?:[^"\\]|\\[\s\S])*)"$"#, options: .regularExpression) {
      let quoted = String(self[range]).replacingOccurrences(of: shell + "\"", with: "", options: .regularExpression).dropLast()
      // Inside double quotes a backslash escapes only `"`, `\`, `$` and a backquote.
      return String(quoted).replacingOccurrences(of: #"\\(["\\$`])"#, with: "$1", options: .regularExpression)
    }
    if let range = range(of: shell + #"'([^']*)'$"#, options: .regularExpression) {
      return String(String(self[range]).replacingOccurrences(of: shell + "'", with: "", options: .regularExpression).dropLast())
    }
    // Codex reports the shell's arguments joined as they were, unescaped:
    // the script is everything between the first quote and the last.
    if let range = range(of: shell + #""[\s\S]*"$"#, options: .regularExpression) {
      return String(String(self[range]).replacingOccurrences(of: shell + "\"", with: "", options: .regularExpression).dropLast())
    }
    return nil
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

/// A harness's own helper, as `AgentRunActivity.workTimelineHelper` finds it.
public struct WorkTimelineHelper: Equatable, Sendable {
  public enum Kind: Hashable, Sendable { case toolLookup, skill }
  public let kind: Kind
  /// What it looked up or loaded, when that is short.
  public var object: String?

  /// Its row: "Looked up render_html", "Loaded the dataviz skill".
  func label(active: Bool, failed: Bool) -> String {
    switch kind {
    case .toolLookup:
      return (failed ? "Failed to look up " : active ? "Looking up " : "Looked up ") + (object ?? "tools")
    case .skill:
      let skill = object.map { "the \($0) skill" } ?? "a skill"
      return (failed ? "Failed to load " : active ? "Loading " : "Loaded ") + skill
    }
  }

  /// One in a narrow column: "1 tool lookup", "dataviz skill".
  var compact: String {
    switch kind {
    case .toolLookup: "1 tool lookup"
    case .skill: object.map { "\($0) skill" } ?? "1 skill"
    }
  }
}

extension WorkTimelineHelper.Kind {
  func noun(count: Int) -> String {
    switch self {
    case .toolLookup: count == 1 ? "tool lookup" : "tool lookups"
    case .skill: count == 1 ? "skill" : "skills"
    }
  }

  /// Two or more: "Ran 2 tool lookups", "Loaded 2 skills".
  func summary(count: Int) -> String {
    switch self {
    case .toolLookup: "Ran \(count) \(noun(count: count))"
    case .skill: "Loaded \(count) \(noun(count: count))"
    }
  }
}

/// What the timeline remembers between rebuilds, which happen on every
/// streamed update: each activity's decoded input, kept while its raw input
/// is the same text, and each run's path anchor once decided.
private final class WorkTimelineMemo: @unchecked Sendable {
  static let shared = WorkTimelineMemo()
  private static let limit = 4_096

  private let lock = NSLock()
  private var inputs: [String: (raw: String, value: [String: Any]?)] = [:]
  private var anchors: [String: String?] = [:]

  func input(id: String, raw: String) -> [String: Any]? {
    lock.lock()
    if let kept = inputs[id], kept.raw == raw {
      lock.unlock()
      return kept.value
    }
    lock.unlock()
    let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    lock.lock()
    if inputs.count >= Self.limit { inputs.removeAll(keepingCapacity: true) }
    inputs[id] = (raw, value)
    lock.unlock()
    return value
  }

  /// The run's anchor: the one first decided, else `decide`'s once it has one.
  func anchor(run: String, decide: () -> String??) -> String? {
    lock.lock()
    if let kept = anchors[run] {
      lock.unlock()
      return kept
    }
    lock.unlock()
    guard let decided = decide() else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let kept = anchors[run] { return kept }
    if anchors.count >= Self.limit { anchors.removeAll(keepingCapacity: true) }
    anchors[run] = decided
    return decided
  }
}
