import CompanionClient
import CryptoKit
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

/// Reopens the full desktop on former nodes without deleting their replica,
/// native workspace or pending command journal. Migration never sends a command.
@MainActor enum LegacyMacLibraryUpgrade {
    static func prepare(database: WorkspaceDatabase, defaults: UserDefaults) async throws {
        guard DevelopmentLaunch.mode == nil, defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey),
              !defaults.bool(forKey: "wovenmatter.paired-macs.legacy-imported") else { return }
        let root = database.supportDirectory
        let legacyLease = try WorkspaceProcessLease(fileURL: root.appending(path: "library-client-owner.lock"))
        defer { withExtendedLifetime(legacyLease) {} }
        let replica = root.appending(path: "LibraryClient/library.json")
        guard FileManager.default.fileExists(atPath: replica.path) else {
            defaults.set(true, forKey: "wovenmatter.paired-macs.legacy-imported"); return
        }
        let store = try MobileStore(file: replica)
        let state = await store.snapshot()
        try await database.backUpBeforePeerSync()
        try await database.adoptLegacyPairedMacIdentity(state.deviceID)
        defaults.set(state.deviceID, forKey: "companion.execution.local-id." + (try await database.companionWorkspaceID()))
        let local = root.appending(path: "LibraryClient/Execution/" + state.deviceID + "/workspace.sqlite")
        if FileManager.default.fileExists(atPath: local.path) {
            // Migrate the private source with the same app version, retaining a
            // WAL-aware snapshot, before importing its local native graph.
            let previous = try await WorkspaceDatabase(url: local)
            try await previous.backUpBeforePeerSync()
            try await database.importLegacyLocalMacWorkspace(from: local)
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
        defaults.set(true, forKey: "wovenmatter.paired-macs.legacy-imported")
    }

    static func reconnect(host: CompanionHostController, defaults: UserDefaults) async throws {
        guard DevelopmentLaunch.mode == nil, defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey),
              defaults.bool(forKey: "wovenmatter.paired-macs.legacy-imported"),
              !defaults.bool(forKey: "wovenmatter.paired-macs.legacy-connected"),
              let credential = try MobileCredentialVault.load(),
              let database = host.model?.dashboardStore?.database else { return }
        // Existing approval/credential is sufficient. No sign-in or re-pairing.
        try await host.peerSync.acceptPairing(endpoint: credential.endpoint,
            response: .init(workspaceID: credential.workspaceID, deviceID: credential.deviceID, credential: credential.token))
        let store = try MobileStore(file: database.supportDirectory.appending(path: "LibraryClient/library.json"))
        let state = await store.snapshot()
        // Preserve exact operation identities, including deletion intent.
        for entry in state.outbox {
            let result = try await database.applyCompanionMutation(entry.mutation)
            if result.status != .accepted, let note = state.notes[entry.mutation.resourceID] {
                try await preserve(note, database: database, deviceID: state.deviceID)
            }
        }
        defaults.set(true, forKey: "wovenmatter.paired-macs.legacy-connected")
        defaults.set(false, forKey: LocalExecutionRole.libraryClientPreferenceKey)
    }

    private static func preserve(_ note: CompanionNote, database: WorkspaceDatabase, deviceID: String) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Array(SHA256.hash(data: try encoder.encode(note)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
        guard try await database.companionNote(id: id) == nil else { return }
        _ = try await database.applyCompanionMutation(.init(deviceID: deviceID, kind: .createNote, resourceID: id,
            title: note.title + " (Saved before pairing upgrade)", content: note.content))
    }
}
