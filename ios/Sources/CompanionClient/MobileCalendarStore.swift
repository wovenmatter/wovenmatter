import Foundation
import WovenMatterCompanion

public struct MobileCalendarConflict: Codable, Equatable, Sendable {
  public var local: CompanionCalendarRecord
  public var remote: CompanionCalendarRecord?
  public var executionConflict: Bool?
}
public typealias MobileCalendarRun = CompanionCalendarRun

/// The UI, native agent tools and command environment share this durable actor.
/// Writes are local immediately. Network failure never rolls back local edits.
public actor MobileCalendarStore {
  private struct Pending: Codable {
    var mutation: CompanionCalendarMutation
    var submitted = false
    var dependsOn: String?
  }
  private struct PreparedDraft: Codable { var arguments: String; var draft: CompanionCalendarDraft }
  private struct Request: Codable { var input: Data; var result: CompanionCalendarRecord }
  private struct State: Codable {
    var workspaceID: String?
    var records: [String: CompanionCalendarRecord] = [:]
    var bases: [String: CompanionCalendarRecord] = [:]
    var outbox: [Pending] = []
    var conflicts: [String: MobileCalendarConflict] = [:]
    var requests: [String: Request] = [:]
    var runs: [String: MobileCalendarRun] = [:]
    var through: [String: Date] = [:]
    var dirtyRuns: Set<String>?
    var preparedDrafts: [String: PreparedDraft]?
    var executionOwners: [String: String]?
  }
  public nonisolated let deviceID: String
  private let file: URL
  private var state: State
  public init(file: URL, deviceID: String) throws {
    self.file = file; self.deviceID = deviceID
    state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
  }
  public func allRecords() -> [CompanionCalendarRecord] { state.records.values.sorted { $0.id < $1.id } }
  public func backupForLibraryTransfer(to file: URL) throws { try MobileStorePersistence.writeDurably(JSONEncoder().encode(state), at: file) }
  public func updateExecutionOwners(_ workspaces: [CompanionExecutionWorkspace]) throws {
    let owners = Dictionary(uniqueKeysWithValues: workspaces.filter { !$0.deleted && $0.kind == .mac && ($0.executionDeviceID ?? $0.ownerDeviceID) == $0.ownerDeviceID }.map { ($0.id, $0.ownerDeviceID) })
    guard owners != state.executionOwners else { return }
    try update { $0.executionOwners = owners }
  }
  /// Merge native execution-database edits against the exact replica version
  /// originally projected there. Both sides survive a concurrent offline edit.
  public func importExecutionRecord(_ record: CompanionCalendarRecord, base: CompanionCalendarRecord?) throws {
    try CompanionCalendarSchedule.validate(record.event.draft)
    guard UUID(uuidString: record.id) != nil else { throw CompanionCalendarError.invalid }
    let current = state.records[record.id]
    func sameContent(_ lhs: CompanionCalendarRecord?, _ rhs: CompanionCalendarRecord?) -> Bool {
      var left = lhs, right = rhs; left?.event.revision = 0; right?.event.revision = 0
      return left == right
    }
    guard !sameContent(current, record) else { return }
    if state.conflicts[record.id] != nil { return }
    if !sameContent(current, base) {
      try update { next in
        next.conflicts[record.id] = .init(local: record, remote: current, executionConflict: true)
        next.records[record.id] = record
        next.outbox.removeAll { $0.mutation.record.id == record.id }
        cancelPending(record.id, in: &next)
      }
      return
    }
    var incoming = record; incoming.event.revision = max((current?.event.revision ?? -1) + 1, record.event.revision)
    try update { next in enqueue(incoming, into: &next); cancelPending(record.id, in: &next) }
  }
  public func importExecutionRuns(_ runs: [CompanionCalendarRun]) throws {
    try update { next in
      for var run in runs {
        guard run.ownerDeviceID == deviceID else { throw CompanionCalendarError.invalid }
        run.revision = next.runs[run.id]?.revision
        if next.runs[run.id] == run { continue }
        run.revision = (next.runs[run.id]?.revision ?? -1) + 1
        next.runs[run.id] = run
        if next.dirtyRuns == nil { next.dirtyRuns = [] }; next.dirtyRuns?.insert(run.id)
        next.through[run.eventID] = max(next.through[run.eventID] ?? .distantPast, run.scheduledAt)
      }
    }
  }
  public func records() -> [CompanionCalendarRecord] { state.records.values.filter { !$0.deleted }.sorted { $0.id < $1.id } }
  public func conflicts() -> [String: MobileCalendarConflict] { state.conflicts }
  public func pendingCount() -> Int { state.outbox.count }
  public func libraryTransferMutations() -> [CompanionCalendarMutation] { state.outbox.map(\.mutation) }
  public func record(id: String) -> CompanionCalendarRecord? { state.records[id].flatMap { $0.deleted ? nil : $0 } }
  public func occurrence(id: String, index: Int) -> CompanionCalendarEvent? { state.records[id].flatMap { CompanionCalendarSchedule.occurrence($0, index: index) } }
  public func events(from: Date, to: Date) throws -> [CompanionCalendarEvent] {
    guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, to > from, to.timeIntervalSince(from) <= 366 * 86_400 else { throw CompanionCalendarError.invalid }
    return state.records.values.filter { !$0.deleted && ($0.event.draft.task == nil || $0.event.draft.showsOnCalendar != false) }.flatMap { record -> [CompanionCalendarEvent] in
      let draft = record.event.draft
      let duration = max(0, (draft.endsAt ?? draft.startsAt).timeIntervalSince(draft.startsAt)) + 86_400
      var index = CompanionCalendarSchedule.index(draft, onOrBefore: from.addingTimeInterval(-duration)) ?? 0
      var result: [CompanionCalendarEvent] = []
      while let date = CompanionCalendarSchedule.date(draft, index: index), date < to {
        if var event = CompanionCalendarSchedule.occurrence(record, index: index), date.addingTimeInterval(max(1, duration - 86_400)) > from {
          if let run = state.runs.values.first(where: { $0.eventID == record.id && $0.scheduledAt == date }) { event.status = run.status; event.sessionID = run.sessionID }
          result.append(event)
        }
        index += 1
      }
      return result
    }.sorted { $0.startsAt == $1.startsAt ? $0.occurrenceID < $1.occurrenceID : $0.startsAt < $1.startsAt }
  }
  public func scheduledTasks() -> [CompanionScheduledTaskItem] {
    records().filter { $0.event.draft.task != nil }.map { record in
      let run = state.runs.values.filter { $0.eventID == record.id }.max { $0.scheduledAt < $1.scheduledAt }
      var event = record.event
      if let run { event.status = run.status; event.sessionID = run.sessionID }
      return .init(event: event, showsOnCalendar: event.draft.showsOnCalendar != false,
        runtimeName: event.draft.task?.runtime == "default_agent" ? "Pi Durable" : event.draft.task!.runtime,
        workspaceName: record.ownerDeviceID == deviceID ? "This device" : record.ownerDeviceID == nil ? "Central Mac" : "Other device", lastRunAt: run?.scheduledAt)
    }.sorted { $0.event.startsAt < $1.event.startsAt }
  }
  public func toolResult(requestID: String, arguments: String) throws -> CompanionCalendarRecord? {
    guard let prepared = state.preparedDrafts?[requestID] else { return nil }
    guard prepared.arguments == arguments else { throw CompanionCalendarError.requestMismatch }
    return state.requests[requestID]?.result
  }
  public func prepareToolDraft(requestID: String, arguments: String, draft: CompanionCalendarDraft) throws -> CompanionCalendarDraft {
    try Task.checkCancellation()
    if let value = state.preparedDrafts?[requestID] {
      guard value.arguments == arguments else { throw CompanionCalendarError.requestMismatch }; return value.draft
    }
    try update { next in
      if next.preparedDrafts == nil { next.preparedDrafts = [:] }
      next.preparedDrafts?[requestID] = .init(arguments: arguments, draft: draft)
    }
    return draft
  }
  @discardableResult public func save(id: String = UUID().uuidString.lowercased(), expectedRevision: Int?, draft: CompanionCalendarDraft,
    ownerDeviceID: String? = nil, requestID: String? = nil) throws -> CompanionCalendarRecord {
    try Task.checkCancellation()
    let input = try Self.encode(SaveInput(id: id, revision: expectedRevision, draft: draft, owner: ownerDeviceID))
    if let result = try replay(requestID, input: input) { return result }
    let draft = try CompanionCalendarSchedule.normalized(draft)
    guard UUID(uuidString: id) != nil,
      ownerDeviceID == nil || draft.task == nil || draft.task?.workspaceID == nil || draft.task?.workspaceID == ownerDeviceID
        || draft.task?.workspaceID.flatMap({ state.executionOwners?[$0] }) == ownerDeviceID else { throw CompanionCalendarError.invalid }
    let current = state.records[id]
    guard current == nil || current?.deleted == false, current?.event.revision == expectedRevision, state.conflicts[id] == nil else { throw CompanionCalendarError.conflict }
    // Ownership is explicit and stable. A device cannot silently take another
    // device's pending task by editing its prompt or calendar appearance.
    if let current, current.event.draft.task != nil, draft.task != nil, current.ownerDeviceID != ownerDeviceID { throw CompanionCalendarError.conflict }
    let record = CompanionCalendarRecord(event: .init(id: id, revision: (current?.event.revision ?? -1) + 1, draft: draft),
      excludedOccurrences: draft.recurrenceUnit == nil ? [] : current?.excludedOccurrences ?? [], ownerDeviceID: draft.task == nil ? nil : ownerDeviceID)
    try update { next in
      enqueue(record, into: &next)
      cancelPending(id, in: &next)
      if let requestID { next.requests[requestID] = .init(input: input, result: record) }
    }
    return record
  }
  public func delete(id: String, expectedRevision: Int, occurrence: Int? = nil, requestID: String? = nil) throws {
    try Task.checkCancellation()
    let input = try Self.encode(DeleteInput(id: id, revision: expectedRevision, occurrence: occurrence))
    if try replay(requestID, input: input) != nil { return }
    guard var record = state.records[id], !record.deleted else { throw CompanionCalendarError.missing }
    guard record.event.revision == expectedRevision, state.conflicts[id] == nil else { throw CompanionCalendarError.conflict }
    if let occurrence {
      guard record.event.draft.recurrenceUnit != nil, CompanionCalendarSchedule.occurrence(record, index: occurrence) != nil else { throw CompanionCalendarError.missing }
      record.excludedOccurrences.insert(occurrence)
    } else { record.deleted = true }
    record.event.revision += 1
    try update { next in
      enqueue(record, into: &next); cancelPending(id, occurrence: occurrence, in: &next)
      if let requestID { next.requests[requestID] = .init(input: input, result: record) }
    }
  }
  @discardableResult public func detach(id: String, expectedRevision: Int, occurrence: Int, draft: CompanionCalendarDraft, requestID: String? = nil) throws -> CompanionCalendarRecord {
    try Task.checkCancellation()
    let input = try Self.encode(DetachInput(id: id, revision: expectedRevision, occurrence: occurrence, draft: draft))
    if let result = try replay(requestID, input: input) { return result }
    let draft = try CompanionCalendarSchedule.normalized(draft)
    guard var parent = state.records[id], !parent.deleted, parent.event.draft.recurrenceUnit != nil,
      parent.event.revision == expectedRevision, state.conflicts[id] == nil,
      CompanionCalendarSchedule.occurrence(parent, index: occurrence) != nil else { throw CompanionCalendarError.conflict }
    parent.excludedOccurrences.insert(occurrence); parent.event.revision += 1
    var independent = draft; independent.recurrenceUnit = nil
    let result = CompanionCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 0, draft: independent), ownerDeviceID: parent.ownerDeviceID)
    try update { next in
      enqueue(parent, into: &next)
      let dependency = next.outbox.last { $0.mutation.record.id == parent.id }?.mutation.id
      enqueue(result, into: &next, dependency: dependency)
      cancelPending(id, occurrence: occurrence, in: &next)
      if let requestID { next.requests[requestID] = .init(input: input, result: result) }
    }
    return result
  }
  /// Resolve explicitly. Keeping the local edit rebases it onto the server's
  /// latest revision; neither version is discarded before this decision.
  public func resolveConflict(id: String, keepLocal: Bool) throws {
    guard let conflict = state.conflicts[id] else { return }
    try update { next in
      let previousIDs = Set(next.outbox.filter { $0.mutation.record.id == id }.map { $0.mutation.id })
      let dependentIDs = next.outbox.filter { $0.dependsOn.map(previousIDs.contains) == true }.map { $0.mutation.record.id }
      next.conflicts[id] = nil; next.outbox.removeAll { $0.mutation.record.id == id }
      if conflict.executionConflict != true { next.bases[id] = conflict.remote }
      if keepLocal {
        guard conflict.remote?.deleted != true else { throw CompanionCalendarError.conflict }
        var local = conflict.local; local.event.revision += 1; enqueue(local, into: &next)
        let replacement = next.outbox.last { $0.mutation.record.id == id }?.mutation.id
        for index in next.outbox.indices where next.outbox[index].dependsOn.map(previousIDs.contains) == true { next.outbox[index].dependsOn = replacement }
      } else {
        next.records[id] = conflict.remote
        if conflict.executionConflict == true, let remote = conflict.remote { enqueue(remote, into: &next) }
        // A detached copy must not upload when exclusion of the original
        // occurrence conflicted. Preserve it for an explicit user decision.
        for child in dependentIDs {
          if let local = next.records[child] { next.conflicts[child] = .init(local: local, remote: next.bases[child]) }
          next.outbox.removeAll { $0.mutation.record.id == child }
        }
      }
    }
  }
  public func moveLocalWriting(to workspaceID: String) throws {
    guard state.workspaceID != workspaceID else { return }
    try update { next in
      // Remote execution schedules belong to their owners. They remain in the
      // recovery copy; moving this phone must never launch those tasks here.
      next.records = next.records.filter { _, record in
        !record.deleted && (record.event.draft.task == nil || record.ownerDeviceID == deviceID)
      }
      next.bases = [:]; next.outbox = []; next.conflicts = next.conflicts.filter { next.records[$0.key] != nil }
      for record in next.records.values.sorted(by: { $0.id < $1.id }) { enqueue(record, into: &next) }
      next.runs = next.runs.filter { $0.value.ownerDeviceID == deviceID && next.records[$0.value.eventID] != nil }
      next.dirtyRuns = Set(next.runs.keys)
      next.through = next.through.filter { next.records[$0.key] != nil }
      next.workspaceID = workspaceID
    }
  }

  public func verifyWorkspace(_ id: String) throws {
    guard state.workspaceID == nil || state.workspaceID == id else { throw CompanionCalendarError.wrongWorkspace }
  }
  public func apply(_ snapshot: CompanionCalendarSnapshot) throws {
    try verifyWorkspace(snapshot.workspaceID)
    try update { next in
      next.workspaceID = snapshot.workspaceID
      for run in snapshot.runs ?? [] where run.ownerDeviceID != deviceID || next.runs[run.id] == nil {
        next.runs[run.id] = run
        if run.ownerDeviceID == deviceID { next.through[run.eventID] = max(next.through[run.eventID] ?? .distantPast, run.scheduledAt) }
      }
      for remote in snapshot.records {
        let dirty = next.outbox.contains { $0.mutation.record.id == remote.id } || next.conflicts[remote.id] != nil
        if !dirty {
          if next.bases[remote.id] != remote {
            var visible = remote
            if let local = next.records[remote.id] { visible.event.revision = max(local.event.revision + 1, remote.event.revision) }
            next.records[remote.id] = visible
            cancelPending(remote.id, in: &next)
          }
          next.bases[remote.id] = remote
        }
        else if next.conflicts[remote.id] != nil { next.conflicts[remote.id]?.remote = remote }
      }
    }
  }
  public func nextMutation() throws -> CompanionCalendarMutation? {
    guard let index = state.outbox.firstIndex(where: { pending in state.conflicts[pending.mutation.record.id] == nil && !state.outbox.contains(where: { $0.mutation.id == pending.dependsOn }) }) else { return nil }
    try update { next in next.outbox[index].submitted = true }
    return state.outbox[index].mutation
  }
  public func acknowledge(_ receipt: CompanionCalendarReceipt) throws {
    guard let index = state.outbox.firstIndex(where: { $0.mutation.id == receipt.mutationID }) else { return }
    let sent = state.outbox[index].mutation
    guard receipt.record == nil || receipt.record?.id == sent.record.id,
      receipt.status != .accepted || receipt.record != nil else { throw CompanionCalendarError.invalidReceipt }
    try update { next in
      if receipt.status == .conflict {
        next.conflicts[sent.record.id] = .init(local: next.records[sent.record.id] ?? sent.record, remote: receipt.record)
        return
      }
      next.outbox.remove(at: index); next.bases[sent.record.id] = receipt.record
      if let following = next.outbox.firstIndex(where: { $0.mutation.record.id == sent.record.id }) {
        next.outbox[following].mutation.expectedRevision = receipt.record?.event.revision
      } else if let remote = receipt.record {
        // Local revision is an editor fence, so never move it backwards after
        // multiple local edits coalesce into one canonical server revision.
        var visible = remote; visible.event.revision = max(remote.event.revision, next.records[remote.id]?.event.revision ?? 0)
        next.records[remote.id] = visible
      }
    }
  }
  /// Claims persist before execution. Only the assigned device can reserve them.
  /// Recurring misses collapse to the latest occurrence; one-offs run late.
  public func dueRuns(deviceID: String, now: Date = Date()) throws -> [MobileCalendarRun] {
    guard deviceID == self.deviceID else { return [] }
    try update { next in
      for record in next.records.values where !record.deleted && record.ownerDeviceID == deviceID && next.conflicts[record.id] == nil {
        guard let task = record.event.draft.task,
          !next.runs.values.contains(where: { $0.eventID == record.id && ["pending", "running"].contains($0.status) }),
          var index = CompanionCalendarSchedule.index(record.event.draft, onOrBefore: now) else { continue }
        while index >= 0 && record.excludedOccurrences.contains(index) { index -= 1 }
        guard let event = CompanionCalendarSchedule.occurrence(record, index: index), event.startsAt > (next.through[record.id] ?? .distantPast) else { continue }
        let previous = next.runs.values.filter { $0.eventID == record.id && $0.status != "cancelled" }.max { $0.scheduledAt < $1.scheduledAt }
        let sessionID = !task.newSessionEachTime && record.event.draft.recurrenceUnit != nil ? previous?.sessionID ?? UUID().uuidString.lowercased() : UUID().uuidString.lowercased()
        let run = MobileCalendarRun(id: UUID().uuidString.lowercased(), eventID: record.id, eventRevision: record.event.revision, ownerDeviceID: deviceID,
          occurrence: index, scheduledAt: event.startsAt, sessionID: sessionID, task: task, title: event.draft.title, status: "pending")
        next.runs[run.id] = run; next.through[record.id] = now
        if next.dirtyRuns == nil { next.dirtyRuns = [] }; next.dirtyRuns?.insert(run.id)
      }
    }
    return state.runs.values.filter { $0.ownerDeviceID == deviceID && $0.status == "pending" }.sorted { $0.scheduledAt < $1.scheduledAt }
  }
  /// Call immediately before dispatch and use run.id as the durable prompt ID.
  /// Running claims are never automatically retried after an uncertain outcome.
  public func beginRun(_ id: String) throws -> MobileCalendarRun {
    guard var run = state.runs[id], run.status == "pending", let event = state.records[run.eventID],
      !event.deleted, event.ownerDeviceID == deviceID, event.event.revision == run.eventRevision,
      !event.excludedOccurrences.contains(run.occurrence), state.conflicts[event.id] == nil else { throw CompanionCalendarError.conflict }
    run.status = "running"; run.revision = (run.revision ?? 0) + 1; try update { $0.runs[id] = run; if $0.dirtyRuns == nil { $0.dirtyRuns = [] }; $0.dirtyRuns?.insert(id) }; return run
  }
  /// Recover only a claim that has not yet reached the durable prompt inbox.
  /// Already-submitted prompts must reconcile by receipt, not by today's event.
  public func recoverRun(_ id: String) throws -> MobileCalendarRun? {
    guard let run = state.runs[id], run.status == "running", run.ownerDeviceID == deviceID else { return nil }
    guard let event = state.records[run.eventID], !event.deleted, event.ownerDeviceID == deviceID,
      event.event.revision == run.eventRevision, !event.excludedOccurrences.contains(run.occurrence), state.conflicts[event.id] == nil else {
      try updateRun(id, status: "cancelled"); return nil
    }
    return run
  }
  public func updateRun(_ id: String, status: String, error: String? = nil) throws {
    guard var run = state.runs[id] else { throw CompanionCalendarError.missing }
    let allowed = run.status == status || (run.status == "pending" && ["failed", "cancelled"].contains(status)) ||
      (run.status == "running" && ["completed", "failed", "cancelled"].contains(status))
    guard allowed else { throw CompanionCalendarError.invalid }
    guard run.status != status || run.error != error else { return }
    run.status = status; run.error = error; run.revision = (run.revision ?? 0) + 1; try update { $0.runs[id] = run; if $0.dirtyRuns == nil { $0.dirtyRuns = [] }; $0.dirtyRuns?.insert(id) }
  }
  public func pendingRuns() -> [CompanionCalendarRun] {
    state.runs.values.filter { run in state.dirtyRuns?.contains(run.id) == true && !state.outbox.contains(where: { $0.mutation.record.id == run.eventID }) && state.conflicts[run.eventID] == nil }
  }
  public func acknowledgeRuns(_ sent: [CompanionCalendarRun]) throws {
    try update { next in for run in sent where next.runs[run.id] == run { next.dirtyRuns?.remove(run.id) } }
  }
  public func runs(eventID: String? = nil) -> [MobileCalendarRun] { state.runs.values.filter { eventID == nil || $0.eventID == eventID }.sorted { $0.scheduledAt < $1.scheduledAt } }
  private func cancelPending(_ id: String, occurrence: Int? = nil, in next: inout State) {
    var cancelled = false
    for key in next.runs.keys where next.runs[key]?.eventID == id && next.runs[key]?.status == "pending" && (occurrence == nil || next.runs[key]?.occurrence == occurrence) {
      next.runs[key]?.status = "cancelled"
      let revision = (next.runs[key]?.revision ?? 0) + 1; next.runs[key]?.revision = revision; cancelled = true
      if next.dirtyRuns == nil { next.dirtyRuns = [] }; next.dirtyRuns?.insert(key)
    }
    if cancelled {
      next.through[id] = next.runs.values.filter { $0.eventID == id && $0.status != "cancelled" }.map(\.scheduledAt).max()
    }
  }
  private func enqueue(_ record: CompanionCalendarRecord, into next: inout State, dependency: String? = nil) {
    if let i = next.outbox.lastIndex(where: { $0.mutation.record.id == record.id }), !next.outbox[i].submitted {
      next.outbox[i].mutation.record = record
    } else { next.outbox.append(.init(mutation: .init(deviceID: deviceID, expectedRevision: next.bases[record.id]?.event.revision, record: record), dependsOn: dependency)) }
    next.records[record.id] = record
  }
  private func replay(_ id: String?, input: Data) throws -> CompanionCalendarRecord? {
    guard let id, let value = state.requests[id] else { return nil }
    guard value.input == input else { throw CompanionCalendarError.requestMismatch }; return value.result
  }
  private func update(_ body: (inout State) throws -> Void) throws {
    var next = state; try body(&next)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try MobileStorePersistence.writeDurably(Self.encode(next), at: file); state = next
  }
  private static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
  private struct SaveInput: Codable { var id: String; var revision: Int?; var draft: CompanionCalendarDraft; var owner: String? }
  private struct DeleteInput: Codable { var id: String; var revision: Int; var occurrence: Int? }
  private struct DetachInput: Codable { var id: String; var revision: Int; var occurrence: Int; var draft: CompanionCalendarDraft }
}
