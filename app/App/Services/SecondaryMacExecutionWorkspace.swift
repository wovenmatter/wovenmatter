import CompanionClient
import Foundation
import Darwin
import CryptoKit
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Optional execution owned by this Mac. The SQLite store here contains native
/// runtime state and a tool-facing projection; the client's replica remains the
/// source for shared notes and the central Mac remains library authority.
@MainActor
final class SecondaryMacExecutionWorkspace: ExecutionWorkspaceTransport {
    struct NoteProjection: Codable {
        var replica: CompanionNote
        var executionRevision: Int64
        var pendingConflict: Bool?
    }
    private struct Projection: Codable {
        var notes: [String: NoteProjection] = [:]
        var folders: [String: CompanionFolder]?
        var nativeHistoryCursors: [String: Int64]?
    }
    private(set) var descriptor: CompanionExecutionWorkspace
    let model: ApplicationModel
    let database: WorkspaceDatabase
    let origin: WorkspaceJournal
    private let replica: MobileStore
    private let directory: URL
    private var projection: Projection
    private var projectionTask: Task<Void, any Error>?
    private var commandsInFlight = 0
    private var acceptsCommands = true
    private var captureTask: Task<Void, any Error>?
    private struct NoteCommand: Codable { let original: CompanionCommand; let localized: CompanionCommand }
    private var noteCommands: [String: NoteCommand] = [:]

    static func create(directory: URL, replica: MobileStore) async throws -> SecondaryMacExecutionWorkspace {
        let state = await replica.snapshot()
        guard let libraryID = state.workspaceID else {
            throw CompanionAPIError(code: "unpaired", message: "Connect this Mac to its central library before enabling its execution workspace.")
        }
        let defaults = UserDefaults(suiteName: "com.wovenmatter.client-execution." + state.deviceID)!
        defaults.set(false, forKey: LocalExecutionRole.libraryClientPreferenceKey)
        let store = try await DashboardStore(supportDirectory: directory)
        let model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false, ownsExecutionOverride: true)
        try await model.configureClientExecutionWorkspace(directory: directory)
        let descriptor = CompanionExecutionWorkspace(id: state.deviceID, libraryID: libraryID, ownerDeviceID: state.deviceID,
            kind: .mac, name: Host.current().localizedName ?? "This Mac", capabilities: ["execution.v1", "inference.v1", "execution.local"], journalDeviceIDs: [state.deviceID])
        return try await SecondaryMacExecutionWorkspace(descriptor: descriptor, model: model, replica: replica, directory: directory)
    }
    init(descriptor: CompanionExecutionWorkspace, model: ApplicationModel, replica: MobileStore, directory: URL) async throws {
        guard let database = model.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        self.descriptor = descriptor; self.model = model; self.database = database; self.replica = replica; self.directory = directory
        origin = try WorkspaceJournal(file: directory.appending(path: "execution-journal.json"))
        let projectionFile = directory.appending(path: "replica-projection.json")
        projection = FileManager.default.fileExists(atPath: projectionFile.path)
            ? try JSONDecoder().decode(Projection.self, from: Data(contentsOf: projectionFile)) : .init()
        let commandsFile = directory.appending(path: "note-command-bindings.json")
        if FileManager.default.fileExists(atPath: commandsFile.path) {
            noteCommands = try JSONDecoder().decode([String: NoteCommand].self, from: Data(contentsOf: commandsFile))
        }
        try await origin.upsertWorkspace(descriptor, pending: false)
        try await reconcileLibrary()
    }
    func setEndpoint(_ endpoint: URL?) async throws {
        descriptor.endpoint = endpoint
        try await origin.upsertWorkspace(descriptor, pending: false)
    }
    var hasActiveRuns: Bool { !model.localRunningConversationIDs.isEmpty }
    func prepareToStop() async throws {
        acceptsCommands = false
        model.backendStopping = true
        do {
            let persisted = try await database.companionSnapshot()
            guard commandsInFlight == 0, !hasActiveRuns, !persisted.conversations.contains(where: { $0.activeRunID != nil }),
                  model.pendingLocalACPPermissions.isEmpty, model.pendingLocalACPInteractions.isEmpty else {
                throw CompanionAPIError(code: "active_execution", message: "Finish or stop this Mac’s running agents and pending approvals before changing its execution workspace.")
            }
            guard await model.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
            try await capture()
            try await model.prepareOpenCodeInstancesToQuit()
            model.shutdownLocalACPSessions()
            await model.dashboardStore?.shutdownLocalACPSessions()
        } catch {
            acceptsCommands = true; model.backendStopping = false
            throw error
        }
    }
    func identity() async throws -> CompanionExecutionWorkspace { descriptor }
    func providers() async throws -> [CompanionProvider] {
        model.companionCommands.providers().filter { $0.id.hasPrefix("local:") }
    }
    func capabilities(_ id: String) async throws -> CompanionProvider { try await model.companionCommands.sessionCapabilities(conversationID: id) }
    func pending() async throws -> [CompanionPendingInteraction] { await model.companionCommands.pendingInteractions() }
    func command(_ request: CompanionCommand) async throws -> CompanionCommandReceipt {
        guard acceptsCommands else { throw CompanionAPIError(code: "stopping", message: "This Mac execution workspace is stopping.") }
        commandsInFlight += 1; defer { commandsInFlight -= 1 }
        guard request.workspaceID == nil || request.workspaceID == descriptor.id else { throw WorkspaceJournal.Failure.wrongLibrary }
        // Pin revision translation before native acceptance, so lost acknowledgements
        // replay the same native bytes even after a projected note changes.
        var command = request
        if let id = request.noteID {
            let key = request.deviceID + ":" + request.commandID
            if let existing = noteCommands[key] {
                guard existing.original == request else {
                    throw CompanionAPIError(code: "reused_command", message: "This command ID was already used for another request.")
                }
                command = existing.localized
            } else {
                try await reconcileLibrary()
                let state = await replica.snapshot()
                guard let shared = state.notes[id], shared.revision == request.noteRevision,
                      state.conflicts[id] == nil, let note = try await database.companionNote(id: id) else {
                    throw CompanionAPIError(code: "note_changed", message: "Sync and review the note before starting this run.")
                }
                command.noteRevision = note.revision
                var next = noteCommands; next[key] = .init(original: request, localized: command)
                try persist(JSONEncoder().encode(next), to: directory.appending(path: "note-command-bindings.json"))
                noteCommands = next
            }
        } else { try await reconcileLibrary() }
        let receipt = try await model.companionCommands.execute(command, deviceID: command.deviceID)
        if let id = receipt.conversationID {
            _ = try await origin.append(workspaceID: descriptor.id, receipt: receipt)
            if request.kind == .createSession { try await recordConversation(id) }
        }
        try await capture()
        return receipt
    }
    func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
        try await model.companionCommands.receipt(commandID: id, deviceID: descriptor.ownerDeviceID)
    }
    func events(after: Int64) async throws -> CompanionJournalPage {
        try await capture()
        let snapshot = await origin.snapshot()
        let entries = snapshot.entries.values.filter { $0.workspaceID == descriptor.id && $0.originSequence > after }
            .sorted { $0.originSequence < $1.originSequence }
        let page = Array(entries.prefix(CompanionFederationProtocol.maximumBatchEntries))
        return .init(libraryID: descriptor.libraryID, cursor: page.last?.originSequence ?? after, entries: page, hasMore: entries.count > page.count)
    }
    func conversations() async throws -> [CompanionConversation] { try await database.companionSnapshot().conversations }
    func transcript(_ id: String) async throws -> CompanionTranscript { try await model.companionCommands.transcript(conversationID: id) }
    func transcript(_ id: String, before: String) async throws -> CompanionTranscript { try await model.companionCommands.transcript(conversationID: id, before: before) }
    func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { try await model.companionCommands.readWorkspace(request) }

    func capture() async throws {
        if let captureTask { return try await captureTask.value }
        let task = Task { try await performCapture() }; captureTask = task
        defer { captureTask = nil }
        try await task.value
    }
    private func performCapture() async throws {
        guard await model.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
        try await reconcileLibrary()
        let snapshot = try await database.companionSnapshot()
        let prior = await origin.snapshot()
        for var conversation in snapshot.conversations {
            conversation.workspaceID = descriptor.id
            conversation.libraryID = descriptor.libraryID
            try await origin.restoreConversation(workspaceID: descriptor.id, conversation: conversation)
            let latest = try await model.companionCommands.transcript(conversationID: conversation.id)
            let known = Set(prior.transcripts[conversation.id]?.messages.map(\.id) ?? [])
            var pages = [latest], cursors = Set<String>()
            while let page = pages.last, let cursor = page.olderCursor {
                if prior.transcripts[conversation.id]?.olderCursor == nil,
                   page.messages.contains(where: { known.contains($0.id) }) { break }
                guard cursors.insert(cursor).inserted else { throw MobileConnectionError.invalidResponse }
                pages.append(try await model.companionCommands.transcript(conversationID: conversation.id, before: cursor))
            }
            _ = try await origin.append(workspaceID: descriptor.id, conversation: conversation)
            // Journal bounded pages separately; a long session must never turn
            // one synchronization event into an unbounded full-history payload.
            for var page in pages.reversed() {
                page.olderCursor = nil
                page.activeRunID = latest.activeRunID
                _ = try await origin.append(workspaceID: descriptor.id, transcript: page)
            }
            try await captureNativeHistory(conversationID: conversation.id)
        }
        try persistProjection()
        let ids = Set(snapshot.conversations.map(\.id))
        for id in prior.conversations.keys where !ids.contains(id) && !prior.deletedConversationIDs.contains(id) {
            let latest = await origin.snapshot()
            try await origin.record(.init(workspaceID: descriptor.id, originSequence: (latest.originSequences[descriptor.id] ?? 0) + 1,
                conversationID: id, kind: .deletedConversation))
        }
    }
    private func captureNativeHistory(conversationID: String) async throws {
        var cursor = projection.nativeHistoryCursors?[conversationID] ?? 0
        while true {
            let records = try await database.executionNativeHistory(conversationID: conversationID, after: cursor)
            guard !records.isEmpty else { return }
            for record in records {
                let identity = conversationID + ":" + record.id
                let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                _ = try await origin.appendNativeRecord(workspaceID: descriptor.id, conversationID: conversationID,
                    runID: record.runID, recordID: "history-" + digest, format: "woven-matter-history.v1", data: record.data)
                cursor = record.sequence
            }
            if projection.nativeHistoryCursors == nil { projection.nativeHistoryCursors = [:] }
            projection.nativeHistoryCursors?[conversationID] = cursor
            try persistProjection()
            if records.count < 32 { return }
        }
    }
    private func recordConversation(_ id: String) async throws {
        if let conversation = try await database.companionSnapshot().conversations.first(where: { $0.id == id }) {
            _ = try await origin.append(workspaceID: descriptor.id, conversation: conversation)
        }
    }

    /// Reconcile outbound tool edits before accepting a fresh inbound projection.
    /// A concurrent replica edit goes through MobileStore's revision ancestry and
    /// produces a retained conflict instead of overwriting either version.
    private func reconcileLibrary() async throws {
        if let projectionTask { return try await projectionTask.value }
        let task = Task { try await performReconcileLibrary() }; projectionTask = task
        defer { projectionTask = nil }
        try await task.value
    }
    private func performReconcileLibrary() async throws {
        var execution = try await database.companionSnapshot(bodyByteBudget: CompanionProtocol.maximumNoteBytes)
        let executionNotes = try await completeNotes(execution.notes)
        var replicaState = await replica.snapshot()
        // Folder identities must be queued before notes that refer to them.
        for folder in execution.folders {
            if replicaState.folders[folder.id] == nil, projection.folders?[folder.id] == nil {
                _ = try await replica.createFolder(name: folder.name, id: folder.id)
            } else if let baseline = projection.folders?[folder.id], folder.name != baseline.name,
                      replicaState.folders[folder.id]?.name == baseline.name {
                try await replica.renameFolder(id: folder.id, name: folder.name)
            }
        }
        let executionIDs = Set(executionNotes.map(\.id))
        for (id, baseline) in projection.notes where !executionIDs.contains(id) {
            do { try await replica.deleteWorkspaceNote(id: id, base: baseline.replica) }
            catch MobileStore.Failure.conflictingNote {
                // A newer replica edit wins over a stale tool deletion. The
                // inbound projection below restores that recoverable content.
            }
        }
        for note in executionNotes {
            if replicaState.conflicts[note.id] != nil || projection.notes[note.id]?.pendingConflict == true { continue }
            if let baseline = projection.notes[note.id] {
                if note.title != baseline.replica.title || note.content != baseline.replica.content || note.folderID != baseline.replica.folderID {
                    var outgoing = note; outgoing.revision = baseline.replica.revision
                    try await replica.importWorkspaceNote(outgoing, base: baseline.replica)
                    if await replica.snapshot().conflicts[note.id] != nil { projection.notes[note.id]?.pendingConflict = true }
                }
            } else if replicaState.notes[note.id] == nil {
                try await replica.importWorkspaceNote(note)
                if await replica.snapshot().conflicts[note.id] != nil {
                    projection.notes[note.id] = .init(replica: note, executionRevision: note.revision, pendingConflict: true)
                }
            }
        }
        replicaState = await replica.snapshot()
        let executionFolderIDs = Set(execution.folders.map(\.id))
        for (id, baseline) in projection.folders ?? [:] where !executionFolderIDs.contains(id) {
            if replicaState.folders[id]?.name == baseline.name {
                do { try await replica.deleteFolder(id: id) }
                catch MobileStore.Failure.conflictingNote { /* Preserve a changed or nonempty folder. */ }
            }
        }
        replicaState = await replica.snapshot()
        for folder in replicaState.folders.values {
            let existing = execution.folders.first { $0.id == folder.id }
            if existing?.name != folder.name {
                let mutation = CompanionMutation(deviceID: descriptor.ownerDeviceID, kind: existing == nil ? .createFolder : .renameFolder,
                    resourceID: folder.id, expectedRevision: existing?.revision, title: folder.name)
                try await applyProjection(mutation)
            }
        }
        execution = try await database.companionSnapshot(bodyByteBudget: CompanionProtocol.maximumNoteBytes)
        for note in replicaState.notes.values where note.contentIncluded {
            let existing = try await database.companionNote(id: note.id)
            if replicaState.conflicts[note.id] != nil { continue }
            if existing?.title != note.title || existing?.content != note.content || existing?.folderID != note.folderID {
                try await applyProjection(.init(deviceID: descriptor.ownerDeviceID, kind: existing == nil ? .createNote : .updateNote,
                    resourceID: note.id, expectedRevision: existing?.revision, folderID: note.folderID, title: note.title, content: note.content))
            }
            if let imported = try await database.companionNote(id: note.id) {
                projection.notes[note.id] = .init(replica: note, executionRevision: imported.revision)
            }
        }
        for (id, _) in projection.notes where replicaState.notes[id] == nil {
            if let existing = try await database.companionNote(id: id) {
                try await applyProjection(.init(deviceID: descriptor.ownerDeviceID, kind: .deleteNote, resourceID: id, expectedRevision: existing.revision))
            }
            projection.notes[id] = nil
        }
        for folder in execution.folders where replicaState.folders[folder.id] == nil {
            let remaining = try await database.companionSnapshot()
            if !remaining.notes.contains(where: { $0.folderID == folder.id }) {
                try await applyProjection(.init(deviceID: descriptor.ownerDeviceID, kind: .deleteFolder,
                    resourceID: folder.id, expectedRevision: folder.revision))
            }
        }
        projection.folders = replicaState.folders
        try persistProjection()
    }
    private func completeNotes(_ notes: [CompanionNote]) async throws -> [CompanionNote] {
        var values: [CompanionNote] = []
        for note in notes {
            if note.contentIncluded { values.append(note) }
            else if let complete = try await database.companionNote(id: note.id) { values.append(complete) }
        }
        return values
    }
    private func applyProjection(_ mutation: CompanionMutation) async throws {
        let result = try await database.applyExecutionReplicaProjection(mutation, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
        guard result.status == .accepted else {
            throw CompanionAPIError(code: "replica_projection_conflict", message: result.message ?? "The shared library projection changed during synchronization.")
        }
    }
    private func persistProjection() throws {
        let file = directory.appending(path: "replica-projection.json")
        try persist(JSONEncoder().encode(projection), to: file)
    }
    private func persist(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appending(path: ".replica-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
        let fd = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}
