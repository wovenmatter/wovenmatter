import CompanionClient
import CryptoKit
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

/// Reopens the full desktop on former nodes without deleting their replica,
/// native workspace or pending command journal. Migration never sends a command.
@MainActor enum LegacyMacLibraryUpgrade {
    static let importedKey = "wovenmatter.paired-macs.legacy-imported"
    static let connectedKey = "wovenmatter.paired-macs.legacy-connected"
    static let failureKey = "wovenmatter.paired-macs.legacy-error"

    /// A former node must finish its same-Mac upgrade under its retained device
    /// identity before exchanging any library content with another Mac.
    static func blocksPeerSync(_ defaults: UserDefaults) -> Bool {
        DevelopmentLaunch.mode == nil && defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey)
            && !defaults.bool(forKey: importedKey)
    }

    /// Never makes the full app unusable. A failure (for example the retired
    /// node's lease is still held) is recorded and retried on the next launch;
    /// paired synchronization stays paused until the upgrade completes.
    static func prepareRecordingFailure(database: WorkspaceDatabase, defaults: UserDefaults) async {
        do { try await prepare(database: database, defaults: defaults); defaults.removeObject(forKey: failureKey) }
        catch { defaults.set(error.localizedDescription, forKey: failureKey) }
    }

    static func prepare(database: WorkspaceDatabase, defaults: UserDefaults) async throws {
        guard DevelopmentLaunch.mode == nil, defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey),
              !defaults.bool(forKey: importedKey) else { return }
        let root = database.supportDirectory
        let legacyLease = try WorkspaceProcessLease(fileURL: root.appending(path: "library-client-owner.lock"))
        defer { withExtendedLifetime(legacyLease) {} }
        let replica = root.appending(path: "LibraryClient/library.json")
        guard FileManager.default.fileExists(atPath: replica.path) else {
            defaults.set(true, forKey: importedKey); return
        }
        let backups = root.appending(path: "Paired Mac Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let retainedReplica = backups.appending(path: "legacy-replica.json")
        if !FileManager.default.fileExists(atPath: retainedReplica.path) { try FileManager.default.copyItem(at: replica, to: retainedReplica) }
        let store = try MobileStore(file: replica)
        let state = await store.snapshot()
        try await database.backUpBeforePeerSync()
        try await database.adoptLegacyPairedMacIdentity(state.deviceID)
        defaults.set(state.deviceID, forKey: "companion.execution.local-id." + (try await database.companionWorkspaceID()))
        let local = root.appending(path: "LibraryClient/Execution/" + state.deviceID + "/workspace.sqlite")
        if FileManager.default.fileExists(atPath: local.path) {
            // Migrate and import a WAL-aware copy. The retained original native
            // database is never modified by this app version.
            let copy = backups.appending(path: "legacy-execution-" + state.deviceID + ".sqlite")
            try WorkspaceDatabase.snapshotDatabase(from: local, to: copy)
            let previous = try await WorkspaceDatabase(url: copy)
            try await database.importLegacyLocalMacWorkspace(from: copy)
            // Startup recovery already ran before this import. Imported runs that
            // were active when the node stopped are recovered now, while this
            // process holds the execution lease and before schedulers start.
            try await database.recoverInterruptedLocalACPRuns()
            let sourceFiles = PairedLibraryFiles(root: local.deletingLastPathComponent())
            let destinationFiles = PairedLibraryFiles(root: root)
            var cursor = ""
            repeat {
                let page = try await sourceFiles.page(after: cursor)
                for file in page.files {
                    while let offset = try await destinationFiles.nextOffset(file) {
                        try await destinationFiles.receive(sourceFiles.chunk(.init(file: file, offset: offset)))
                    }
                }
                cursor = page.cursor
                if !page.hasMore { break }
            } while true
            // Projected central notes are not imported: the central's own rows
            // arrive through pairing. Writing that only ever existed in this
            // node's execution workspace is preserved under a recovery identity.
            let known = Set(state.notes.keys).union(state.outbox.map(\.mutation.resourceID))
            for id in try await previous.legacyLiveNoteIDs() where !known.contains(id) {
                if let note = try await previous.companionNote(id: id) { try await preserve(note, database: database, deviceID: state.deviceID) }
            }
        }
        // Cached writing is preserved under deterministic recovery identities.
        // It cannot overwrite newer writing on a paired Mac during first sync.
        for note in state.notes.values where note.contentIncluded {
            try await preserve(note, database: database, deviceID: state.deviceID)
        }
        for conflict in state.conflicts.values { try await preserve(conflict.local, database: database, deviceID: state.deviceID) }
        for draft in state.chatDrafts.values where !draft.text.isEmpty {
            let content = try NoteDocument(blocks: [.richText(.init(text: draft.text))]).encoded()
            try await preserve(.init(id: "draft", title: "Unsent message", content: content, revision: 0), database: database, deviceID: state.deviceID)
        }
        for record in try await store.dictations.pending() { try await database.saveDictation(record) }
        defaults.set(true, forKey: importedKey)
    }

    /// Pending writing is reconciled at the original approved Mac with its
    /// original operation IDs, so that Mac's receipts make lost replies exact
    /// and its expected revisions keep their meaning. Every unapplied intent is
    /// preserved visibly; nothing is replayed against this Mac's fresh library.
    /// Agent commands are never replayed. Only then does pairing begin.
    static func reconnect(host: CompanionHostController, defaults: UserDefaults,
                          makeTransport: (MobileCredential) throws -> any CompanionTransport = { try HTTPSCompanionTransport(credential: $0) }) async throws {
        guard DevelopmentLaunch.mode == nil, defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey),
              defaults.bool(forKey: importedKey), !defaults.bool(forKey: connectedKey),
              let database = host.model?.dashboardStore?.database else { return }
        let store = try MobileStore(file: database.supportDirectory.appending(path: "LibraryClient/library.json"))
        let state = await store.snapshot()
        guard let credential = try host.peerSync.loadLegacyCredential() else {
            // Never paired: no approved Mac exists to reconcile with.
            for entry in state.outbox { try await preserveUnapplied(entry, state: state, database: database) }
            return finish(defaults)
        }
        let transport = try makeTransport(credential)
        var revoked = false
        for entry in state.outbox {
            let result: CompanionMutationResult
            do { result = try await transport.mutate(entry.mutation) }
            catch MobileConnectionError.revoked { revoked = true; break }
            if result.status == .accepted { continue }
            // A delete whose target is already gone has achieved its intent.
            if entry.mutation.kind == .deleteNote || entry.mutation.kind == .deleteFolder, result.status == .notFound { continue }
            try await preserveUnapplied(entry, state: state, database: database)
        }
        if revoked {
            // The original Mac unpaired this node; its intent stays visible locally.
            for entry in state.outbox { try await preserveUnapplied(entry, state: state, database: database) }
            return finish(defaults)
        }
        // Existing approval/credential is sufficient. No sign-in or re-pairing.
        try await host.peerSync.acceptPairing(endpoint: credential.endpoint,
            response: .init(workspaceID: credential.workspaceID, deviceID: credential.deviceID, credential: credential.token))
        finish(defaults)
    }

    private static func finish(_ defaults: UserDefaults) {
        defaults.set(true, forKey: connectedKey)
        defaults.set(false, forKey: LocalExecutionRole.libraryClientPreferenceKey)
    }

    private static func preserveUnapplied(_ entry: MobileOutboxEntry, state: MobileStoreState, database: WorkspaceDatabase) async throws {
        let mutation = entry.mutation
        switch mutation.kind {
        case .createNote, .updateNote:
            let cached = state.notes[mutation.resourceID]
            let note = CompanionNote(id: mutation.resourceID, title: mutation.title ?? cached?.title ?? "Untitled note",
                content: mutation.content ?? cached?.content ?? "", revision: 0)
            try await preserve(note, database: database, deviceID: state.deviceID)
        case .deleteNote:
            let cached = state.notes[mutation.resourceID] ?? state.pendingNoteDeletions?[mutation.resourceID]
            let text = "This note was deleted on this Mac before the pairing upgrade, but the deletion was not applied because the note changed elsewhere."
            let content = try cached.flatMap { $0.contentIncluded ? $0.content : nil }
                ?? NoteDocument(blocks: [.richText(.init(text: text))]).encoded()
            try await preserve(.init(id: mutation.resourceID, title: (cached?.title ?? "Note") + " (Deletion not applied before pairing upgrade)", content: content, revision: 0),
                database: database, deviceID: state.deviceID, operationID: mutation.operationID, describes: true)
        case .createFolder, .renameFolder, .deleteFolder:
            let action = mutation.kind == .deleteFolder ? "Delete folder" : mutation.kind == .renameFolder ? "Rename folder to “\(mutation.title ?? "")”" : "Create folder “\(mutation.title ?? "")”"
            let content = try NoteDocument(blocks: [.richText(.init(text: action + " was not applied before the pairing upgrade. Reapply it if it is still needed."))]).encoded()
            try await preserve(.init(id: mutation.resourceID, title: "Folder change not applied before pairing upgrade", content: content, revision: 0),
                database: database, deviceID: state.deviceID, operationID: mutation.operationID, describes: true)
        }
    }

    private static func preserve(_ note: CompanionNote, database: WorkspaceDatabase, deviceID: String, operationID: String? = nil, describes: Bool = false) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // An unapplied operation has exactly one recovery identity, however
        // often reconciliation is retried.
        let seed = try operationID.map { Data(("unapplied:" + $0).utf8) } ?? encoder.encode(note)
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
        guard try await database.companionNote(id: id) == nil else { return }
        _ = try await database.applyCompanionMutation(.init(deviceID: deviceID, kind: .createNote, resourceID: id,
            title: describes ? note.title : note.title + " (Saved before pairing upgrade)", content: note.content))
    }
}
