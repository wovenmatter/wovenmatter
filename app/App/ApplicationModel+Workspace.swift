import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func createFolder(name: String) async -> String? {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let folderID = try await dashboardStore.createFolder(name: name)
            await refreshWorkspace()
            return folderID
        } catch {
            folderMutationError = error.localizedDescription
            return nil
        }
    }

    func renameFolder(id: String, name: String) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.renameFolder(id: id, name: name)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func setFolderPinned(id: String, isPinned: Bool) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.setFolderPinned(id: id, isPinned: isPinned)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            guard try await dashboardStore.moveFolder(
                id: id,
                direction: direction
            ) else {
                folderMutationError = "The folder could not be moved."
                return false
            }
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func deleteFolder(id: String) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.deleteFolder(id: id)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func clearFolderMutationError() {
        folderMutationError = nil
    }

    func moveConversation(id: String, toFolderID folderID: String?) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let moved = try await dashboardStore.moveConversation(id: id, toFolderID: folderID)
            if !moved {
                folderMutationError = "The chat could not be moved."
                return false
            }
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func createNote(
        folderID: String?,
        kind: NoteArtifactKind = .note
    ) async -> String? {
        noteMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let noteID = try await dashboardStore.createNote(
                folderID: folderID,
                kind: kind
            )
            await refreshWorkspace()
            return noteID
        } catch {
            noteMutationError = error.localizedDescription
            return nil
        }
    }

    func createCalendarItem(
        title: String,
        startsAt: Date,
        endsAt: Date?,
        allDay: Bool
    ) async -> Bool {
        calendarMutationError = nil
        isCreatingCalendarItem = true
        defer { isCreatingCalendarItem = false }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.createCalendarItem(
                title: title,
                startsAt: startsAt,
                endsAt: endsAt,
                allDay: allDay
            )
            await refreshWorkspace()
            return true
        } catch {
            calendarMutationError = error.localizedDescription
            return false
        }
    }

    func clearCalendarMutationError() {
        calendarMutationError = nil
    }

    func noteDraft(for note: WorkspaceNoteRecord) -> DashboardNoteDraft {
        noteDrafts[note.id] ?? .initial(for: note)
    }

    func noteCLIEnvironment(noteID: String) -> [String: String] {
        guard let noteEditingSocketPath,
              let cliURL = Bundle.main.resourceURL?.appending(path: "woven-note") else {
            return [:]
        }
        var environment = [
            "WOVEN_NOTE_ID": noteID,
            "WOVEN_NOTE_SOCKET": noteEditingSocketPath,
            "WOVEN_NOTE_CLI": cliURL.path,
        ]
        if let databasesURL = localACPWorkspaceLaunchConfiguration?.databasesURL {
            environment["WOVEN_DATABASES_DIR"] = databasesURL.path
        }
        return environment
    }

    func adoptNoteEditingResponse(_ response: NoteEditingResponse) async {
        guard adoptNoteEditingResponseDraft(response) else { return }
        await refreshWorkspace()
    }

    @discardableResult
    func adoptNoteEditingResponseDraft(_ response: NoteEditingResponse) -> Bool {
        guard response.success, let document = response.document,
              let content = try? document.encoded() else { return false }
        if var draft = noteDrafts[response.noteID] {
            draft.title = response.title ?? draft.title
            draft.content = content
            draft.saveState = .saved
            draft.editRevision = 0
            draft.persistedRevision = 0
            draft.sourceUpdatedAt = response.revision
            noteDrafts[response.noteID] = draft
        }
        return true
    }

    func prepareNoteDraft(_ note: WorkspaceNoteRecord) {
        guard var draft = noteDrafts[note.id] else {
            noteDrafts[note.id] = noteDraft(for: note)
            return
        }
        draft.reconcile(with: note)
        noteDrafts[note.id] = draft
    }

    func updateNoteDraft(
        note: WorkspaceNoteRecord,
        title: String? = nil,
        content: String? = nil
    ) {
        prepareNoteDraft(note)
        guard var draft = noteDrafts[note.id] else { return }
        draft.edit(title: title, content: content)
        persistNoteDraft(note: note, draft: draft)
    }

    func retryNoteDraft(note: WorkspaceNoteRecord) {
        prepareNoteDraft(note)
        guard var draft = noteDrafts[note.id] else { return }
        draft.editRevision &+= 1
        draft.saveState = .saving
        persistNoteDraft(note: note, draft: draft)
    }

    func persistNoteDraft(
        note: WorkspaceNoteRecord,
        draft: DashboardNoteDraft
    ) {
        var draft = draft
        guard let noteWriteBehind else {
            let error = ApplicationModelError.dashboardStoreUnavailable
            draft.fail(error.localizedDescription)
            noteDrafts[note.id] = draft
            noteMutationError = error.localizedDescription
            return
        }
        let entry = DashboardNoteJournalEntry(
            noteID: note.id,
            title: draft.title,
            content: draft.content,
            revision: draft.editRevision,
            folderID: note.folderID,
            createdAt: note.createdAt
        )
        noteDrafts[note.id] = draft
        noteWriteBehind.submit(entry)
    }

    @discardableResult
    func flushNoteDrafts() -> Bool {
        guard let noteWriteBehind else { return false }
        do {
            try noteWriteBehind.flush()
            return true
        } catch {
            noteMutationError = error.localizedDescription
            return false
        }
    }

    func completeNoteWrite(
        _ entry: DashboardNoteJournalEntry,
        result: Result<Void, any Error>
    ) {
        guard var draft = noteDrafts[entry.noteID] else { return }
        switch result {
        case .success:
            draft.persistedRevision = max(draft.persistedRevision, entry.revision)
            if draft.editRevision == entry.revision {
                draft.saveState = .saved
            }
            let hasOutstandingWork = noteWriteBehind?.hasOutstandingWork()
            if hasOutstandingWork == false {
                noteMutationError = nil
            }
            noteDrafts[entry.noteID] = draft
            if dashboardStoreStartDeferredForNoteRecovery,
               hasOutstandingWork == false {
                dashboardStoreStartDeferredForNoteRecovery = false
                startDashboardStoreIfReady()
            }
            noteRefreshTask?.cancel()
            noteRefreshTask = Task {
                guard !Task.isCancelled else { return }
                await refreshWorkspace()
            }
        case .failure(let error):
            if draft.editRevision <= entry.revision {
                draft.fail(error.localizedDescription)
                noteDrafts[entry.noteID] = draft
                noteMutationError = error.localizedDescription
            }
        }
    }

    func clearNoteMutationError() {
        noteMutationError = nil
    }
    func refreshDatabases() async {
        if isRefreshingDatabases {
            databaseRefreshRequestedWhileRunning = true
            await withCheckedContinuation { continuation in
                databaseRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingDatabases = true
        defer {
            isRefreshingDatabases = false
            let waiters = databaseRefreshWaiters
            databaseRefreshWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
        }

        repeat {
            databaseRefreshRequestedWhileRunning = false
            var sources: [DashboardDatabaseSource] = []
            if let root = localACPWorkspaceLaunchConfiguration?.databasesURL {
                do {
                    let rows = try await Task.detached(priority: .utility) {
                        try AgentDatabaseCatalog.list(at: root)
                    }.value
                    sources.append(Self.databaseSource(
                        id: "local",
                        name: "Local workspace",
                        kind: .local,
                        detail: root.path,
                        rows: rows,
                        allowsCreation: true,
                        allowsExternalLinks: true
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: "local",
                        name: "Local workspace",
                        kind: .local,
                        detail: root.path,
                        databases: [],
                        error: error.localizedDescription,
                        allowsCreation: true,
                        allowsExternalLinks: true
                    ))
                }
            } else {
                sources.append(DashboardDatabaseSource(
                    id: "local",
                    name: "Local workspace",
                    kind: .local,
                    detail: "Set up the local agent workspace in Settings.",
                    databases: [],
                    error: localACPWorkspaceAvailability.detail,
                    allowsCreation: false,
                    allowsExternalLinks: false
                ))
            }

            let remoteCatalogIdentity = remoteWorkspaces.databaseCatalogIdentity
            let configurations = remoteCatalogIdentity.configurations
            for configuration in configurations {
                let sourceID = Self.remoteDatabaseSourceID(configuration.id)
                do {
                    let rows = try await remoteWorkspaces.databases(for: configuration)
                    sources.append(DashboardDatabaseSource(
                        id: sourceID, name: configuration.name, kind: .remote,
                        detail: "\(configuration.hostName) · Databases",
                        databases: rows.map { DashboardAgentDatabase(
                            sourceID: sourceID, databaseID: $0.id, name: $0.name,
                            preference: $0.preference, localURL: nil, isExternal: false
                        ) }, error: nil, allowsCreation: true, allowsExternalLinks: false
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: sourceID, name: configuration.name, kind: .remote,
                        detail: configuration.hostName, databases: [],
                        error: error is CancellationError ? "Workspace connection changed. Refresh to reconnect." : error.localizedDescription,
                        allowsCreation: false, allowsExternalLinks: false
                    ))
                }
            }
            for link in buzzWorkspaceSnapshot.links where link.isEnabled {
                let sourceID = "buzz:\(link.id.uuidString.lowercased())"
                let root = link.localWorkspaceURL.appending(
                    path: LocalACPWorkspaceProvisioner.databasesDirectoryName,
                    directoryHint: .isDirectory
                )
                do {
                    let rows = try await Task.detached(priority: .utility) {
                        try AgentDatabaseCatalog.list(at: root)
                    }.value
                    sources.append(Self.databaseSource(
                        id: sourceID,
                        name: link.displayName,
                        kind: .buzz,
                        detail: root.path,
                        rows: rows
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: sourceID,
                        name: link.displayName,
                        kind: .buzz,
                        detail: root.path,
                        databases: [],
                        error: error.localizedDescription,
                        allowsCreation: false,
                        allowsExternalLinks: false
                    ))
                }
            }

            guard remoteCatalogIdentity == remoteWorkspaces.databaseCatalogIdentity else {
                databaseRefreshRequestedWhileRunning = true
                continue
            }
            databasesSnapshot = DashboardDatabasesSnapshot(sources: sources)
        } while databaseRefreshRequestedWhileRunning
    }

    static func remoteDatabaseSourceID(_ id: UUID) -> String {
        "remote:\(id.uuidString.lowercased())"
    }

    private func remoteDatabaseConfiguration(sourceID: String) -> RemoteWorkspaceConfiguration? {
        remoteWorkspaces.workspaces.first { Self.remoteDatabaseSourceID($0.id) == sourceID }
    }

    @discardableResult
    func createDatabase(sourceID: String, name: String, preference: AgentDatabasePreference) async -> String? {
        if sourceID == "local" { return await createLocalDatabase(name: name, preference: preference) }
        guard let configuration = remoteDatabaseConfiguration(sourceID: sourceID) else {
            databaseError = "Choose an available workspace."
            return nil
        }
        do {
            let row = try await remoteWorkspaces.createDatabase(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), preference: preference, in: configuration)
            databaseError = nil
            await refreshDatabases()
            return "\(sourceID):\(row.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createLocalDatabase(
        name: String,
        preference: AgentDatabasePreference
    ) async -> String? {
        guard let root = localACPWorkspaceLaunchConfiguration?.databasesURL else {
            databaseError = "Set up the local agent workspace before creating a database."
            return nil
        }
        do {
            let database = try await Task.detached(priority: .userInitiated) {
                try AgentDatabaseCatalog.create(
                    named: name,
                    preference: preference,
                    in: root
                )
            }.value
            databaseError = nil
            await refreshDatabases()
            return "local:\(database.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func registerExternalDatabase(_ url: URL) async -> String? {
        guard let root = localACPWorkspaceLaunchConfiguration?.databasesURL else {
            databaseError = "Set up the local agent workspace before linking a database."
            return nil
        }
        do {
            let database = try await Task.detached(priority: .userInitiated) {
                try AgentDatabaseCatalog.registerExternal(url, in: root)
            }.value
            databaseError = nil
            await refreshDatabases()
            return "local:\(database.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    func updateDatabasePreference(
        _ preference: AgentDatabasePreference,
        database: DashboardAgentDatabase
    ) async {
        guard updatingDatabasePreferenceIDs.insert(database.id).inserted else { return }
        defer { updatingDatabasePreferenceIDs.remove(database.id) }
        do {
            if let configuration = remoteDatabaseConfiguration(sourceID: database.sourceID) {
                try await remoteWorkspaces.setDatabasePreference(preference, databaseID: database.databaseID, in: configuration)
            } else if let url = database.localURL {
                try await Task.detached(priority: .userInitiated) {
                    try AgentDatabaseCatalog.setPreference(preference, for: url)
                }.value
            } else {
                throw DashboardDatabaseLinkError.databaseUnavailable
            }
            databaseError = nil
            await refreshDatabases()
        } catch {
            databaseError = error.localizedDescription
        }
    }

    func clearDatabaseError() {
        databaseError = nil
    }

    func linkedData(for link: DatabaseArtifactLink) async throws -> DatabaseTabularData {
        if let configuration = remoteDatabaseConfiguration(sourceID: link.sourceID) {
            let result = try await remoteWorkspaces.databaseData(for: link, in: configuration)
            let identity = remoteWorkspaces.databaseCatalogIdentity
            let data = try await Task.detached(priority: .utility) {
                if let query = result.query { return try DatabaseLinkedData.load(queryResponse: query) }
                guard let encoded = result.jsonBase64, let data = Data(base64Encoded: encoded) else {
                    throw DashboardDatabaseLinkError.remoteDataUnavailable
                }
                return try DatabaseLinkedData.load(data: data, fileExtension: "json", preference: .json, sqliteQuery: nil)
            }.value
            guard identity == remoteWorkspaces.databaseCatalogIdentity else { throw CancellationError() }
            try Task.checkCancellation()
            return data
        }
        var database = databasesSnapshot.database(
            sourceID: link.sourceID,
            databaseID: link.databaseID
        )
        if database == nil {
            await refreshDatabases()
            database = databasesSnapshot.database(
                sourceID: link.sourceID,
                databaseID: link.databaseID
            )
        }
        guard let database else {
            throw DashboardDatabaseLinkError.databaseUnavailable
        }
        if let databaseURL = database.localURL {
            return try await Task.detached(priority: .utility) {
                let fileExtension = URL(
                    fileURLWithPath: link.relativePath
                ).pathExtension.lowercased()
                if DatabaseLinkedData.requiresSQLiteFileAccess(
                    fileExtension: fileExtension,
                    preference: database.preference
                ) {
                    return try AgentDatabaseCatalog.withConfinedSQLiteFile(
                        relativePath: link.relativePath,
                        in: databaseURL
                    ) { stagedURL in
                        try DatabaseLinkedData.load(
                            from: stagedURL,
                            preference: .sqlite,
                            sqliteQuery: link.sqliteQuery
                        )
                    }
                }
                let data = try AgentDatabaseCatalog.readDataFile(
                    relativePath: link.relativePath,
                    in: databaseURL,
                    maximumBytes: DatabaseLinkedData.maximumFileBytes
                )
                return try DatabaseLinkedData.load(
                    data: data,
                    fileExtension: fileExtension,
                    preference: database.preference,
                    sqliteQuery: link.sqliteQuery
                )
            }.value
        }

        throw DashboardDatabaseLinkError.remoteDataUnavailable
    }

    private nonisolated static func databaseSource(
        id: String,
        name: String,
        kind: DashboardDatabaseSourceKind,
        detail: String,
        rows: [LocalAgentDatabase],
        allowsCreation: Bool = false,
        allowsExternalLinks: Bool = false
    ) -> DashboardDatabaseSource {
        DashboardDatabaseSource(
            id: id,
            name: name,
            kind: kind,
            detail: detail,
            databases: rows.map {
                DashboardAgentDatabase(
                    sourceID: id,
                    databaseID: $0.id,
                    name: $0.name,
                    preference: $0.preference,
                    localURL: $0.url,
                    isExternal: $0.isExternal
                )
            },
            error: nil,
            allowsCreation: allowsCreation,
            allowsExternalLinks: allowsExternalLinks
        )
    }
}
