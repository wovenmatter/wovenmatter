import CompanionClient
import Foundation
import Darwin
import WovenMatterCompanion
import WovenMatterDashboardStore

/// The secondary Mac's native runtime needs a SQLite calendar, while shared
/// calendar edits belong to its durable replica. Baselines preserve both revision
/// ancestries so neither a tool nor a synchronized edit overwrites the other.
@MainActor
final class SecondaryMacCalendarProjection {
    private struct Baseline: Codable {
        var replica: CompanionCalendarRecord
        var native: CompanionCalendarRecord
    }
    private struct Projection: Codable {
        var baselines: [String: Baseline] = [:]
        var pendingConflicts: Set<String> = []
    }
    private let database: WorkspaceDatabase
    private let replica: MobileStore
    private let descriptor: CompanionExecutionWorkspace
    private let file: URL
    private var projection: Projection
    private var pending: (id: UUID, task: Task<Void, any Error>)?

    init(database: WorkspaceDatabase, replica: MobileStore, descriptor: CompanionExecutionWorkspace, directory: URL) throws {
        self.database = database; self.replica = replica; self.descriptor = descriptor
        file = directory.appending(path: "calendar-replica-projection.json")
        projection = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Projection.self, from: Data(contentsOf: file)) : .init()
    }

    func reconcile() async throws {
        let operation: (id: UUID, task: Task<Void, any Error>)
        if let pending { operation = pending }
        else {
            operation = (UUID(), Task { try await self.performReconcile() })
            pending = operation
        }
        // Any waiter may resume first. Clear only the generation it joined,
        // allowing a following command to start a fresh projection cycle.
        defer { if pending?.id == operation.id { pending = nil } }
        try await operation.task.value
    }

    private func performReconcile() async throws {
        let nativeRows = try await database.executionCalendarSnapshot(libraryID: descriptor.libraryID, workspaceID: descriptor.id).records
        let native = Dictionary(uniqueKeysWithValues: nativeRows.map { ($0.id, $0) })
        let initialReplica = Dictionary(uniqueKeysWithValues: await replica.calendar.allRecords().map { ($0.id, $0) })
        let initialConflicts = await replica.calendar.conflicts()
        projection.pendingConflicts.formUnion(initialConflicts.keys)
        for record in nativeRows where initialConflicts[record.id] == nil && !projection.pendingConflicts.contains(record.id) {
            let outbound = sharedRecord(record)
            if let baseline = projection.baselines[record.id] {
                if !sameContent(record, baseline.native) {
                    try await replica.calendar.importExecutionRecord(outbound, base: baseline.replica)
                }
            } else if let current = initialReplica[record.id], sameContent(outbound, current) {
                // Recover a crash after the projection committed but before its
                // baseline file did. Equality proves there is no divergent edit.
            } else {
                try await replica.calendar.importExecutionRecord(outbound, base: nil)
            }
        }

        let conflicts = await replica.calendar.conflicts()
        projection.pendingConflicts.formUnion(conflicts.keys)
        try await database.setExecutionCalendarConflicts(ids: Set(conflicts.keys).union(projection.pendingConflicts), libraryID: descriptor.libraryID, workspaceID: descriptor.id)
        // Remember conflict provenance before accepting a resolution. Otherwise
        // a retained native edit could be exported again after the user chose
        // the replica version, reopening the same conflict indefinitely.
        try persist()
        for record in await replica.calendar.allRecords() where conflicts[record.id] == nil {
            let previous = native[record.id]
            let projected: CompanionCalendarRecord
            if let previous, sameContent(nativeRecord(record), previous) { projected = previous }
            else {
                // Use the native revision captured before exporting. A tool edit
                // during an actor suspension fails this CAS and is exported next.
                projected = try await database.projectExecutionCalendar(record, expectedRevision: previous?.event.revision,
                    libraryID: descriptor.libraryID, workspaceID: descriptor.id)
            }
            projection.baselines[record.id] = .init(replica: record, native: projected)
            projection.pendingConflicts.remove(record.id)
        }
        // Do not release a resolved task until its native CAS has succeeded.
        // An interrupted projection keeps the stale task fenced on restart.
        try await database.setExecutionCalendarConflicts(ids: Set(conflicts.keys).union(projection.pendingConflicts),
            libraryID: descriptor.libraryID, workspaceID: descriptor.id)
        try await replica.calendar.importExecutionRuns(database.executionCalendarRuns(workspaceID: descriptor.id))
        try persist()
    }

    private func sharedRecord(_ value: CompanionCalendarRecord) -> CompanionCalendarRecord {
        var result = value
        if result.ownerDeviceID == "central" { result.ownerDeviceID = nil }
        else if result.event.draft.task != nil, result.ownerDeviceID == nil {
            result.ownerDeviceID = descriptor.ownerDeviceID
        }
        if var task = result.event.draft.task, result.ownerDeviceID == descriptor.ownerDeviceID, task.workspaceID == nil {
            task.workspaceID = descriptor.id; result.event.draft.task = task
        }
        return result
    }
    private func nativeRecord(_ value: CompanionCalendarRecord) -> CompanionCalendarRecord {
        var result = value
        if result.event.draft.task != nil {
            if result.ownerDeviceID == nil { result.ownerDeviceID = "central" }
            if var task = result.event.draft.task, result.ownerDeviceID == descriptor.ownerDeviceID, task.workspaceID == descriptor.id {
                task.workspaceID = nil; result.event.draft.task = task
            }
        }
        return result
    }
    private func sameContent(_ left: CompanionCalendarRecord, _ right: CompanionCalendarRecord) -> Bool {
        var left = left, right = right
        left.event.revision = 0; right.event.revision = 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func normalized(_ value: CompanionCalendarRecord) -> CompanionCalendarRecord {
            var value = value
            value.event.startsAt = formatter.date(from: formatter.string(from: value.event.startsAt))!
            value.event.draft.startsAt = formatter.date(from: formatter.string(from: value.event.draft.startsAt))!
            value.event.draft.endsAt = value.event.draft.endsAt.map { formatter.date(from: formatter.string(from: $0))! }
            value.event.draft.showsOnCalendar = value.event.draft.showsOnCalendar ?? true
            if value.event.draft.task != nil, value.event.draft.task?.enabledTools == nil {
                value.event.draft.task?.enabledTools = WorkspaceToolGroup.allCases.filter { $0 != .executor }.map { "wovenmatter_" + $0.rawValue }.sorted()
            }
            return value
        }
        return normalized(left) == normalized(right)
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(projection)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.deletingLastPathComponent().appending(path: ".calendar-projection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
        let fd = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}
