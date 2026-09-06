import Darwin
import Foundation
import WovenMatterCore

struct DashboardNoteJournalEntry: Codable, Equatable, Sendable {
    static let currentVersion = 3

    let version: Int
    let writerSessionID: String?
    let mutationID: String?
    let noteID: String
    let title: String
    let content: String
    let revision: UInt64
    let folderID: String?
    let createdAt: String?

    init(
        writerSessionID: String? = nil,
        mutationID: String = UUID().uuidString.lowercased(),
        noteID: String,
        title: String,
        content: String,
        revision: UInt64,
        folderID: String? = nil,
        createdAt: String? = nil
    ) {
        version = Self.currentVersion
        self.writerSessionID = writerSessionID
        self.mutationID = mutationID
        self.noteID = noteID
        self.title = title
        self.content = content
        self.revision = revision
        self.folderID = folderID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, writerSessionID, mutationID
        case noteID, title, content, revision, folderID, createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        writerSessionID = try values.decodeIfPresent(String.self, forKey: .writerSessionID)
        mutationID = try values.decodeIfPresent(String.self, forKey: .mutationID)
        noteID = try values.decode(String.self, forKey: .noteID)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decode(String.self, forKey: .content)
        revision = try values.decode(UInt64.self, forKey: .revision)
        folderID = try values.decodeIfPresent(String.self, forKey: .folderID)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func identified(by writerSessionID: String) -> DashboardNoteJournalEntry {
        DashboardNoteJournalEntry(
            writerSessionID: writerSessionID,
            mutationID: mutationID ?? UUID().uuidString.lowercased(),
            noteID: noteID,
            title: title,
            content: content,
            revision: revision,
            folderID: folderID,
            createdAt: createdAt
        )
    }
}

final class DashboardNoteDraftJournal: @unchecked Sendable {
    typealias BeforeAppend = @Sendable () throws -> Void

    private let fileURL: URL
    private let lockFileURL: URL
    private let beforeAppend: BeforeAppend
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL,
        beforeAppend: @escaping BeforeAppend = {}
    ) {
        self.fileURL = fileURL
        lockFileURL = fileURL.appendingPathExtension("lock")
        self.beforeAppend = beforeAppend
    }

    func append(_ entry: DashboardNoteJournalEntry) throws {
        try withExclusiveLock {
            _ = try entriesUnlocked()
            try beforeAppend()
            try ensureFileUnlocked()
            var record = try encoder.encode(entry)
            record.append(0x0A)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
            try handle.synchronize()
        }
    }

    func entries() throws -> [DashboardNoteJournalEntry] {
        try withExclusiveLock { try entriesUnlocked() }
    }

    func latestEntries() throws -> [DashboardNoteJournalEntry] {
        latestNoteJournalEntries(from: try entries())
    }

    func compactToLatestEntries() throws {
        try withExclusiveLock {
            let latest = latestNoteJournalEntries(from: try entriesUnlocked())
            var data = Data()
            for entry in latest {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try writeCompactedUnlocked(data)
        }
    }

    func acknowledge(_ acknowledged: DashboardNoteJournalEntry) throws {
        try withExclusiveLock {
            let entries = try entriesUnlocked()
            let targetIndex: Int?
            if let mutationID = acknowledged.mutationID {
                targetIndex = entries.firstIndex { $0.mutationID == mutationID }
            } else {
                targetIndex = entries.firstIndex { $0 == acknowledged }
            }
            guard let targetIndex else { return }
            let remaining: [DashboardNoteJournalEntry] = entries.enumerated().compactMap {
                index, entry in
                if index == targetIndex { return nil }
                if index < targetIndex,
                   let writerSessionID = acknowledged.writerSessionID,
                   entry.noteID == acknowledged.noteID,
                   entry.writerSessionID == writerSessionID {
                    return nil
                }
                return entry
            }
            var data = Data()
            for entry in remaining {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try writeCompactedUnlocked(data)
        }
    }

    private func entriesUnlocked() throws -> [DashboardNoteJournalEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        try repairPartialTailUnlocked()
        let data = try Data(contentsOf: fileURL)
        let records = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var entries: [DashboardNoteJournalEntry] = []
        var foundMalformedRecord = false
        for record in records {
            do {
                entries.append(try decoder.decode(
                    DashboardNoteJournalEntry.self,
                    from: Data(record)
                ))
            } catch {
                foundMalformedRecord = true
            }
        }
        if foundMalformedRecord {
            try quarantineAndRewriteUnlocked(entries)
        }
        return entries
    }

    private func ensureFileUnlocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw DashboardNoteJournalError.createFailed
            }
            try synchronizeParentDirectoryUnlocked()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func repairPartialTailUnlocked() throws {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty, data.last != 0x0A else { return }
        let validLength = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(validLength))
        try handle.synchronize()
    }

    private func quarantineAndRewriteUnlocked(
        _ entries: [DashboardNoteJournalEntry]
    ) throws {
        let quarantineURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).ndjson")
        try FileManager.default.copyItem(at: fileURL, to: quarantineURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: quarantineURL.path
        )
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try writeCompactedUnlocked(data)
    }

    private func writeCompactedUnlocked(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeParentDirectoryUnlocked()
    }

    private func synchronizeParentDirectoryUnlocked() throws {
        let directory = fileURL.deletingLastPathComponent().path
        let descriptor = directory.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.currentPOSIXError()
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            let directory = lockFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let descriptor = lockFileURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw Self.currentPOSIXError() }
            defer { Darwin.close(descriptor) }
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
                throw Self.currentPOSIXError()
            }
            defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
            return try operation()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

}

enum DashboardNoteJournalError: Error {
    case createFailed
}

final class DashboardNoteWriteBehind: @unchecked Sendable {
    typealias Update = @Sendable (DashboardNoteJournalEntry) throws -> Void
    typealias Completion = @Sendable (
        DashboardNoteJournalEntry,
        Result<Void, any Error>
    ) -> Void

    private let journal: DashboardNoteDraftJournal
    private let update: Update
    private let completion: Completion
    private let queue = DispatchQueue(label: "com.wovenmatter.note-write-behind")
    private let coalescingDelay: DispatchTimeInterval
    private let writerSessionID: String
    private var pending: [String: DashboardNoteJournalEntry] = [:]
    private var order: [String] = []
    private var scheduledGeneration: UInt64 = 0
    private var stickyAppendError: (any Error)?

    init(
        journal: DashboardNoteDraftJournal,
        coalescingDelay: DispatchTimeInterval = .milliseconds(700),
        writerSessionID: String = UUID().uuidString.lowercased(),
        update: @escaping Update,
        completion: @escaping Completion
    ) {
        self.journal = journal
        self.coalescingDelay = coalescingDelay
        self.writerSessionID = writerSessionID
        self.update = update
        self.completion = completion
    }

    func submit(_ entry: DashboardNoteJournalEntry) {
        // Keystrokes update application state immediately and are coalesced on
        // this serial queue. Lifecycle flush barriers close the short window
        // before the latest entry reaches the recoverable on-disk journal.
        let identifiedEntry = entry.identified(by: writerSessionID)
        queue.async { [self] in
            enqueue(identifiedEntry)
            scheduleDrain()
        }
    }

    func replayAndFlush(_ entries: [DashboardNoteJournalEntry]) async throws {
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                scheduledGeneration &+= 1
                if let error = processJournaled(latestNoteJournalEntries(from: entries)) {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func flush() throws {
        var failure: (any Error)?
        queue.sync { [self] in
            scheduledGeneration &+= 1
            failure = drainPending()
        }
        if let failure {
            throw failure
        }
    }

    func hasOutstandingWork() -> Bool {
        queue.sync {
            guard pending.isEmpty else { return true }
            do {
                return try !journal.entries().isEmpty
            } catch {
                return true
            }
        }
    }

    private func enqueue(_ entry: DashboardNoteJournalEntry) {
        if pending[entry.noteID] == nil { order.append(entry.noteID) }
        if pending[entry.noteID, default: entry].revision <= entry.revision {
            pending[entry.noteID] = entry
        }
    }

    private func scheduleDrain() {
        scheduledGeneration &+= 1
        let generation = scheduledGeneration
        queue.asyncAfter(deadline: .now() + coalescingDelay) { [self] in
            guard generation == scheduledGeneration else { return }
            _ = drainPending()
        }
    }

    private func drainPending() -> (any Error)? {
        let entries = order.compactMap { pending[$0] }
        order.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        guard !entries.isEmpty else { return stickyAppendError }

        var firstFailure: (any Error)?
        var appendFailure: (any Error)?
        for entry in entries {
            do {
                try journal.append(entry)
            } catch {
                enqueue(entry)
                if appendFailure == nil { appendFailure = error }
                if firstFailure == nil { firstFailure = error }
                completion(entry, .failure(error))
                continue
            }

            let result = persistJournaled(entry)
            if case .failure(let error) = result, firstFailure == nil {
                firstFailure = error
            }
            completion(entry, result)
        }
        stickyAppendError = appendFailure
        return firstFailure
    }

    private func processJournaled(
        _ entries: [DashboardNoteJournalEntry]
    ) -> (any Error)? {
        var firstFailure: (any Error)?
        for entry in entries {
            let result = persistJournaled(entry)
            if case .failure(let error) = result, firstFailure == nil {
                firstFailure = error
            }
            completion(entry, result)
        }
        return firstFailure
    }

    private func persistJournaled(
        _ entry: DashboardNoteJournalEntry
    ) -> Result<Void, any Error> {
        do {
            try update(entry)
            try journal.acknowledge(entry)
            return .success(())
        } catch {
            // Each record is a complete note snapshot. If SQLite remains
            // unavailable, retaining only each note's latest durable snapshot
            // prevents retry/edit traffic from growing the journal without
            // bound while preserving the last-mutation order across notes.
            try? journal.compactToLatestEntries()
            return .failure(error)
        }
    }

}

enum DashboardNoteDraftSaveState: Equatable {
    case saved
    case saving
    case failed(String)
}

struct DashboardNoteDraft: Equatable {
    var title: String
    var content: String
    var saveState: DashboardNoteDraftSaveState
    var editRevision: UInt64
    var persistedRevision: UInt64
    var sourceUpdatedAt: String?

    static func initial(for note: WorkspaceNoteRecord) -> DashboardNoteDraft {
        DashboardNoteDraft(
            title: note.title,
            content: note.content,
            saveState: .saved,
            editRevision: 0,
            persistedRevision: 0,
            sourceUpdatedAt: note.updatedAt
        )
    }

    static func recovered(
        from entry: DashboardNoteJournalEntry,
        source note: WorkspaceNoteRecord?
    ) -> DashboardNoteDraft {
        DashboardNoteDraft(
            title: entry.title,
            content: entry.content,
            saveState: .saving,
            editRevision: entry.revision,
            persistedRevision: 0,
            sourceUpdatedAt: note?.updatedAt
        )
    }

    mutating func reconcile(with note: WorkspaceNoteRecord) {
        if editRevision == 0 {
            adopt(note)
        } else if note.title == title, note.content == content {
            saveState = .saved
            sourceUpdatedAt = note.updatedAt
            if persistedRevision >= editRevision {
                editRevision = 0
                persistedRevision = 0
            }
        } else if persistedRevision < editRevision {
            // A local write is still pending. A refresh cannot supersede it.
        } else if note.updatedAt == sourceUpdatedAt {
            // A pane can reopen before the post-write snapshot refresh arrives.
            // Keep both the newer draft and its current save result.
        } else {
            // A newer local writer (including woven-note) won the revision.
            adopt(note)
        }
    }

    mutating func edit(title: String? = nil, content: String? = nil) {
        if let title { self.title = title }
        if let content { self.content = content }
        editRevision &+= 1
        saveState = .saving
    }

    mutating func fail(_ message: String) {
        saveState = .failed(message)
    }

    private mutating func adopt(_ note: WorkspaceNoteRecord) {
        title = note.title
        content = note.content
        saveState = .saved
        editRevision = 0
        persistedRevision = 0
        sourceUpdatedAt = note.updatedAt
    }
}

private func latestNoteJournalEntries(
    from entries: [DashboardNoteJournalEntry]
) -> [DashboardNoteJournalEntry] {
    var latestIndex: [String: [String: Int]] = [:]
    var retained = Array(repeating: true, count: entries.count)
    for (index, entry) in entries.enumerated() {
        guard let writerSessionID = entry.writerSessionID else { continue }
        if let previous = latestIndex[entry.noteID]?[writerSessionID] {
            retained[previous] = false
        }
        latestIndex[entry.noteID, default: [:]][writerSessionID] = index
    }
    return entries.enumerated().compactMap { index, entry in
        retained[index] ? entry : nil
    }
}
