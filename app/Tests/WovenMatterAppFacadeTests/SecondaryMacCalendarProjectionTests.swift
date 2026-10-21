import CompanionClient
import Foundation
import Testing
import WovenMatterCompanion
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite("Secondary Mac offline calendar projection", .serialized)
struct SecondaryMacCalendarProjectionTests {

    @Test func offlineUIAndNativeAgentEditsShareCalendarAndSyncWithoutRevisionChurn() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let saved = try await f.replica.calendar.save(expectedRevision: nil,
            draft: .init(title: "Offline UI", startsAt: Date(timeIntervalSince1970: 1_700_000_000.123456), timeZoneID: "UTC"))
        try await f.bridge.reconcile()
        let initial = try #require(try await f.database.calendarItems().first)
        #expect(initial.title == "Offline UI")
        try await f.bridge.reconcile()
        try await f.restartBridge().reconcile()
        #expect(try await f.database.calendarItems().first?.calendar.revision == initial.calendar.revision)
        try await f.synchronize()
        try await f.bridge.reconcile()
        let current = try #require(try await f.database.calendarItems().first)
        var edit = WorkspaceCalendarDraft(current); edit.title = "Native agent edit"
        _ = try await f.database.saveCalendarEvent(id: saved.id, draft: edit, creating: false, expectedRevision: current.calendar.revision)
        try await f.bridge.reconcile()
        #expect(await f.replica.calendar.record(id: saved.id)?.event.draft.title == edit.title)
        try await f.synchronize()
        #expect(try await f.central.calendarItems().map(\.title) == [edit.title])
        let projectedRevision = try #require(try await f.database.calendarItems().first?.calendar.revision)
        try await f.restartBridge().reconcile()
        #expect(try await f.database.calendarItems().first?.calendar.revision == projectedRevision)
        #expect(await f.replica.calendar.pendingCount() == 0)
    }


    @Test func crashAfterReplicaImportBeforeBaselinePersistenceDoesNotDuplicateOrConflict() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let id = try await f.database.saveCalendarEvent(draft: .init(title: "Native creation", startsAt: Date(timeIntervalSince1970: 1_700_000_000), timeZoneID: "UTC"), creating: true)
        let native = try #require(try await f.database.companionCalendarSnapshot().records.first)
        try await f.replica.calendar.importExecutionRecord(native, base: nil)
        // The sidecar baseline does not yet exist, as if the process stopped
        // immediately after the durable replica accepted the native creation.
        try await f.restartBridge().reconcile()
        #expect(await f.replica.calendar.conflicts().isEmpty)
        #expect(await f.replica.calendar.allRecords().map(\.id) == [id])
        #expect(await f.replica.calendar.pendingCount() == 1)
        try await f.synchronize()
        #expect(try await f.central.calendarItems().map(\.id) == [id])
    }

    @MainActor private struct Fixture {
        let directory: URL
        let database: WorkspaceDatabase
        let central: WorkspaceDatabase
        let replica: MobileStore
        let descriptor: CompanionExecutionWorkspace
        let bridge: SecondaryMacCalendarProjection
        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "secondary-calendar-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try await WorkspaceDatabase(url: directory.appending(path: "execution.sqlite"))
            central = try await WorkspaceDatabase(url: directory.appending(path: "central.sqlite"))
            replica = try MobileStore(file: directory.appending(path: "client/library.json"))
            let library = try await central.companionLibraryIdentity().libraryID
            try await replica.apply(CompanionSnapshot(workspaceID: library, cursor: 0))
            let owner = await replica.snapshot().deviceID
            descriptor = .init(id: owner, libraryID: library, ownerDeviceID: owner, kind: .mac, name: "Test Mac")
            bridge = try SecondaryMacCalendarProjection(database: database, replica: replica, descriptor: descriptor, directory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func synchronize() async throws {
            while let mutation = try await replica.calendar.nextMutation() {
                let receipt = try await central.companionCalendarMutate(mutation, deviceID: descriptor.ownerDeviceID)
                try await replica.calendar.acknowledge(receipt)
            }
        }
        func restartBridge() throws -> SecondaryMacCalendarProjection {
            try .init(database: database, replica: replica, descriptor: descriptor, directory: directory)
        }
    }

    @Test func concurrentNativeAndReplicaEditsRetainBothAndResolutionSurvivesRestart() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let initial = try await f.replica.calendar.save(expectedRevision: nil,
            draft: .init(title: "Initial", startsAt: Date(timeIntervalSince1970: 1_700_000_000), timeZoneID: "UTC"))
        try await f.bridge.reconcile(); try await f.synchronize(); try await f.bridge.reconcile()
        let native = try #require(try await f.database.calendarItems().first)
        let replica = try #require(await f.replica.calendar.record(id: initial.id))
        var localDraft = replica.event.draft; localDraft.title = "Replica edit"
        _ = try await f.replica.calendar.save(id: replica.id, expectedRevision: replica.event.revision, draft: localDraft)
        var nativeDraft = WorkspaceCalendarDraft(native); nativeDraft.title = "Native edit"
        _ = try await f.database.saveCalendarEvent(id: native.id, draft: nativeDraft, creating: false, expectedRevision: native.calendar.revision)
        try await f.bridge.reconcile()
        let conflict = try #require(await f.replica.calendar.conflicts()[initial.id])
        #expect(conflict.local.event.draft.title == "Native edit")
        #expect(conflict.remote?.event.draft.title == "Replica edit")
        #expect(try await f.database.calendarItems().first?.title == "Native edit")
        try await f.replica.calendar.resolveConflict(id: initial.id, keepLocal: false)
        let restarted = try f.restartBridge(); try await restarted.reconcile()
        #expect(await f.replica.calendar.conflicts().isEmpty)
        #expect(try await f.database.calendarItems().first?.title == "Replica edit")
        try await f.synchronize(); try await f.restartBridge().reconcile()
        #expect(try await f.central.calendarItems().first?.title == "Replica edit")
        #expect(await f.replica.calendar.conflicts().isEmpty)
    }

    @Test func onlyAssignedMacTasksExecuteAndNativeHarnessRunReceiptsSyncCentrally() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let phone = UUID().uuidString.lowercased()
        let foreign = [CompanionCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
            draft: .init(title: "Central task", startsAt: start, timeZoneID: "UTC", task: .init(prompt: "Central", runtime: "codex")))),
            .init(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
            draft: .init(title: "Phone task", startsAt: start, timeZoneID: "UTC", task: .init(prompt: "Phone", workspaceID: phone))), ownerDeviceID: phone)]
        try await f.replica.calendar.apply(.init(workspaceID: f.descriptor.libraryID, records: foreign))
        let local = try await f.replica.calendar.save(expectedRevision: nil, draft: .init(title: "Mac task", startsAt: start,
            timeZoneID: "UTC", task: .init(prompt: "Local", runtime: "codex", workspaceID: f.descriptor.id,
                enabledTools: ["wovenmatter_calendar"])), ownerDeviceID: f.descriptor.ownerDeviceID)
        try await f.bridge.reconcile()
        let nativeID = try await f.database.saveCalendarEvent(draft: .init(title: "Native Claude task", startsAt: start, timeZoneID: "UTC",
            task: .init(prompt: "Other native harness", configuration: .init(runtimeKind: .claudeCode, title: "Native Claude task",
                nativeWorkingDirectory: "/tmp/project", tools: .init(enabled: [.calendar])))), creating: true, now: start)
        try await f.bridge.reconcile()
        let runs = try await f.database.dueCalendarRuns(now: start.addingTimeInterval(1))
        #expect(Set(runs.map(\.eventID)) == Set([local.id, nativeID]))
        #expect(runs.first { $0.eventID == local.id }?.task.configuration.tools.enabled == [.calendar, .goals])
        #expect(runs.first { $0.eventID == nativeID }?.task.configuration.runtimeKind == .claudeCode)
        #expect(runs.first { $0.eventID == nativeID }?.task.configuration.nativeWorkingDirectory == "/tmp/project")
        for run in runs { #expect(try await f.database.isCalendarRunActive(run.id)) }
        let selected = try #require(runs.first { $0.eventID == local.id })
        _ = try await f.database.createLocalACPSession(runtimeKind: .codex, title: selected.title, ownerDeviceID: UUID(),
            requestedConversationID: UUID(uuidString: selected.sessionID))
        _ = try await f.database.prepareCalendarDelivery(runID: selected.id, now: start)
        #expect(try await f.database.claimToolDelivery(id: selected.id, now: start) != nil)
        try await f.database.setToolDeliveryStatus(id: selected.id, status: "accepted")
        try await f.database.settleCalendarRuns()
        try await f.bridge.reconcile(); try await f.synchronize()
        let receipts = await f.replica.calendar.pendingRuns()
        #expect(receipts.first { $0.id == selected.id }?.status == "accepted")
        #expect(receipts.allSatisfy { $0.ownerDeviceID == f.descriptor.ownerDeviceID })
        _ = try await f.central.companionCalendarPublishRuns(receipts, deviceID: f.descriptor.ownerDeviceID)
        #expect(try await f.central.companionCalendarSnapshot().runs?.first { $0.id == selected.id }?.status == "accepted")
        #expect(try await f.central.dueCalendarRuns(now: start.addingTimeInterval(1)).isEmpty)
        let before = await f.replica.calendar.pendingRuns()
        try await f.restartBridge().reconcile()
        #expect(await f.replica.calendar.pendingRuns() == before)
    }

    @Test func taskConflictsFenceNativeExecutionAndToolOnlyEditsRemainRestricted() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try await f.replica.calendar.save(expectedRevision: nil, draft: .init(title: "Event to task", startsAt: start, timeZoneID: "UTC"))
        try await f.bridge.reconcile()
        let event = try #require(try await f.database.calendarItems().first)
        var nativeDraft = WorkspaceCalendarDraft(event)
        nativeDraft.task = .init(prompt: "Native task", configuration: .init(runtimeKind: .claudeCode, title: event.title,
            tools: .init(enabled: [.calendar, .notes])))
        _ = try await f.database.saveCalendarEvent(id: event.id, draft: nativeDraft, creating: false, expectedRevision: event.calendar.revision)
        try await f.bridge.reconcile()
        let owned = try #require(await f.replica.calendar.record(id: original.id))
        #expect(owned.ownerDeviceID == f.descriptor.ownerDeviceID)
        #expect(owned.event.draft.task?.enabledTools == ["wovenmatter_calendar", "wovenmatter_goals", "wovenmatter_notes"])
        let claimed = try #require(try await f.database.dueCalendarRuns(now: start).first)
        // A task-only capability edit must be exported even if title and dates
        // are unchanged; the scheduled session may never gain extra groups.
        let before = try #require(try await f.database.calendarItems().first)
        var restricted = WorkspaceCalendarDraft(before); restricted.task?.configuration.tools.enabled = [.calendar]
        _ = try await f.database.saveCalendarEvent(id: before.id, draft: restricted, creating: false, expectedRevision: before.calendar.revision)
        try await f.bridge.reconcile()
        #expect(await f.replica.calendar.record(id: original.id)?.event.draft.task?.enabledTools == ["wovenmatter_calendar", "wovenmatter_goals"])
        let native = try #require(try await f.database.calendarItems().first)
        let replica = try #require(await f.replica.calendar.record(id: original.id))
        var localDraft = replica.event.draft; localDraft.task?.prompt = "Replica prompt"
        _ = try await f.replica.calendar.save(id: replica.id, expectedRevision: replica.event.revision, draft: localDraft, ownerDeviceID: replica.ownerDeviceID)
        var nativeEdit = WorkspaceCalendarDraft(native); nativeEdit.task?.prompt = "Native prompt"
        _ = try await f.database.saveCalendarEvent(id: native.id, draft: nativeEdit, creating: false, expectedRevision: native.calendar.revision)
        try await f.bridge.reconcile()
        #expect(await f.replica.calendar.conflicts()[original.id] != nil)
        #expect(try await f.database.dueCalendarRuns(now: start).isEmpty)
        #expect(try await !f.database.isCalendarRunActive(claimed.id))
        try await f.replica.calendar.resolveConflict(id: original.id, keepLocal: false)
        try await f.restartBridge().reconcile()
        let resumed = try #require(try await f.database.dueCalendarRuns(now: start).first)
        #expect(resumed.task.prompt == "Replica prompt")
        #expect(resumed.task.configuration.tools.enabled == [.calendar, .goals])
    }

}
