import Darwin
import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

struct DashboardMessagePresentation: Sendable {
    let source: String
    let status: String?
    let createdAt: String
    let document: ConversationMarkdownDocument?
}

struct DashboardRunPresentation: Sendable {
    let source: WorkspaceRunRecord
    let startedAt: Date?
    let completedDuration: String?
}

struct PendingLocalACPPermission: Equatable, Identifiable {
    let id: UUID
    let conversationID: String
    let title: String
    let options: [LocalACPPermissionOption]
}

struct PendingLocalACPInteraction: Equatable, Identifiable {
    let id: UUID
    let conversationID: String
    let request: LocalACPInteractionRequest
}

struct PreparedLocalACPRuntimeInstall: Equatable, Identifiable {
    let definition: LocalACPRuntimeDefinition
    let preview: LocalACPInstallerPreview

    var id: AgentRuntimeKind { definition.runtimeKind }
}

struct ConversationTitleGenerationSettings: Equatable {
    var isEnabled: Bool
    var model: String
    var thinking: String
}

struct DashboardConversationWindow: Equatable, Sendable {
    let conversationID: String
    let messages: [WorkspaceMessageRecord]
    let runs: [WorkspaceRunRecord]
    let activities: [WorkspaceRunActivityRecord]
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    let hasOlderMessages: Bool
    let loadedOlderMessages: Bool

    init(page: WorkspaceConversationHistoryPage) {
        conversationID = page.conversationID
        runs = page.runs
        activities = page.activities
        attachments = page.attachments
        references = page.references
        messages = Self.ordered(messages: page.messages, runs: page.runs)
        hasOlderMessages = page.hasOlderMessages
        loadedOlderMessages = false
    }

    func refreshing(with page: WorkspaceConversationHistoryPage) -> DashboardConversationWindow {
        guard page.conversationID == conversationID, loadedOlderMessages,
              let tailStart = page.oldestMessageCursor else {
            return DashboardConversationWindow(page: page)
        }
        // Completed history outside the live tail is product-defined as immutable.
        // Preserve the already paged prefix instead of requerying it on every refresh;
        // if sent-message editing or deletion is added, revalidate this prefix here.
        let retainedMessages = messages.filter {
            Self.cursor(for: $0).precedes(tailStart)
        }
        let retainedMessageIDs = Set(retainedMessages.map(\.id))
        let retainedRuns = runs.filter {
            $0.userMessageID.map(retainedMessageIDs.contains) == true
                || $0.assistantMessageID.map(retainedMessageIDs.contains) == true
        }
        let retainedRunIDs = Set(retainedRuns.map(\.id))
        let retainedActivities = activities.filter { retainedRunIDs.contains($0.runID) }
        let retainedAttachments = attachments.filter { retainedMessageIDs.contains($0.messageID) }
        let retainedReferences = references.filter { retainedMessageIDs.contains($0.messageID) }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: retainedMessages, with: page.messages),
            runs: Self.merged(runs: retainedRuns, with: page.runs),
            activities: Self.merged(activities: retainedActivities, with: page.activities),
            attachments: Self.merged(attachments: retainedAttachments, with: page.attachments),
            references: Self.merged(references: retainedReferences, with: page.references),
            hasOlderMessages: retainedMessages.isEmpty ? page.hasOlderMessages : hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    func prepending(_ page: WorkspaceConversationHistoryPage) -> DashboardConversationWindow {
        guard page.conversationID == conversationID else {
            return DashboardConversationWindow(page: page)
        }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: page.messages, with: messages),
            runs: Self.merged(runs: page.runs, with: runs),
            activities: Self.merged(activities: page.activities, with: activities),
            attachments: Self.merged(attachments: page.attachments, with: attachments),
            references: Self.merged(references: page.references, with: references),
            hasOlderMessages: page.hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    func mergingNewer(_ newer: DashboardConversationWindow) -> DashboardConversationWindow {
        guard newer.conversationID == conversationID else { return newer }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: messages, with: newer.messages),
            runs: Self.merged(runs: runs, with: newer.runs),
            activities: Self.merged(activities: activities, with: newer.activities),
            attachments: Self.merged(attachments: attachments, with: newer.attachments),
            references: Self.merged(references: references, with: newer.references),
            hasOlderMessages: hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    private init(
        conversationID: String,
        messages: [WorkspaceMessageRecord],
        runs: [WorkspaceRunRecord],
        activities: [WorkspaceRunActivityRecord],
        attachments: [WorkspaceMessageAttachmentRecord],
        references: [WorkspaceMessageReferenceRecord],
        hasOlderMessages: Bool,
        loadedOlderMessages: Bool
    ) {
        self.conversationID = conversationID
        self.runs = runs
        self.activities = activities
        self.attachments = attachments
        self.references = references
        self.messages = Self.ordered(messages: messages, runs: runs)
        self.hasOlderMessages = hasOlderMessages
        self.loadedOlderMessages = loadedOlderMessages
    }

    private static func cursor(for message: WorkspaceMessageRecord) -> WorkspaceConversationHistoryCursor {
        WorkspaceConversationHistoryCursor(createdAt: message.createdAt, messageID: message.id)
    }

    private static func merged(
        messages first: [WorkspaceMessageRecord],
        with second: [WorkspaceMessageRecord]
    ) -> [WorkspaceMessageRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for message in second {
            byID[message.id] = message
        }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private static func merged(
        runs first: [WorkspaceRunRecord],
        with second: [WorkspaceRunRecord]
    ) -> [WorkspaceRunRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for run in second {
            byID[run.id] = run
        }
        return byID.values.sorted {
            let firstCreatedAt = $0.createdAt ?? ""
            let secondCreatedAt = $1.createdAt ?? ""
            return firstCreatedAt == secondCreatedAt ? $0.id < $1.id : firstCreatedAt < secondCreatedAt
        }
    }

    private static func merged(
        activities first: [WorkspaceRunActivityRecord],
        with second: [WorkspaceRunActivityRecord]
    ) -> [WorkspaceRunActivityRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for activity in second { byID[activity.id] = activity }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private static func merged(
        attachments first: [WorkspaceMessageAttachmentRecord],
        with second: [WorkspaceMessageAttachmentRecord]
    ) -> [WorkspaceMessageAttachmentRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for attachment in second { byID[attachment.id] = attachment }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private static func merged(
        references first: [WorkspaceMessageReferenceRecord],
        with second: [WorkspaceMessageReferenceRecord]
    ) -> [WorkspaceMessageReferenceRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for reference in second { byID[reference.id] = reference }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    /// Server and Mac clocks can differ enough for a response timestamp to
    /// precede the prompt that caused it. Use timestamps as the baseline, then
    /// enforce the causal user -> assistant relationship carried by each run.
    private static func ordered(
        messages: [WorkspaceMessageRecord],
        runs: [WorkspaceRunRecord]
    ) -> [WorkspaceMessageRecord] {
        let chronological = messages.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        let messageIDs = Set(chronological.map(\.id))
        var prerequisites: [String: Set<String>] = [:]
        for run in runs {
            guard let userMessageID = run.userMessageID,
                  let assistantMessageID = run.assistantMessageID,
                  userMessageID != assistantMessageID,
                  messageIDs.contains(userMessageID),
                  messageIDs.contains(assistantMessageID) else { continue }
            prerequisites[assistantMessageID, default: []].insert(userMessageID)
        }
        guard !prerequisites.isEmpty else { return chronological }

        var emitted: Set<String> = []
        var remaining = chronological
        var result: [WorkspaceMessageRecord] = []
        result.reserveCapacity(chronological.count)
        while !remaining.isEmpty {
            guard let nextIndex = remaining.firstIndex(where: { message in
                prerequisites[message.id, default: []].isSubset(of: emitted)
            }) else {
                // Malformed cyclic relationships must not make messages vanish.
                result.append(contentsOf: remaining)
                break
            }
            let next = remaining.remove(at: nextIndex)
            emitted.insert(next.id)
            result.append(next)
        }
        return result
    }
}

private extension WorkspaceConversationHistoryCursor {
    func precedes(_ other: WorkspaceConversationHistoryCursor) -> Bool {
        createdAt == other.createdAt ? messageID < other.messageID : createdAt < other.createdAt
    }
}

private struct DashboardConversationPresentation: Sendable {
    let window: DashboardConversationWindow
    let messagesByID: [String: DashboardMessagePresentation]
    let runsByID: [String: DashboardRunPresentation]

    var content: WorkspaceConversationContent {
        WorkspaceConversationContent(
            conversationID: window.conversationID,
            messages: window.messages,
            runs: window.runs,
            attachments: window.attachments,
            references: window.references
        )
    }
}

@MainActor
@Observable
final class DashboardConversationState {
    let conversationID: String
    private(set) var content: WorkspaceConversationContent?
    private(set) var messagePresentations: [String: DashboardMessagePresentation] = [:]
    private(set) var runPresentations: [String: DashboardRunPresentation] = [:]
    private(set) var runActivities: [WorkspaceRunActivityRecord] = []
    private(set) var hasOlderMessages = false
    private(set) var isLoadingOlderMessages = false
    private(set) var error: String?
    @ObservationIgnored fileprivate var presentation: DashboardConversationPresentation?
    @ObservationIgnored fileprivate var lastAccessSequence: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    fileprivate func apply(_ presentation: DashboardConversationPresentation) {
        self.presentation = presentation
        content = presentation.content
        messagePresentations = presentation.messagesByID
        runPresentations = presentation.runsByID
        runActivities = presentation.window.activities
        hasOlderMessages = presentation.window.hasOlderMessages
    }

    fileprivate func setLoadingOlderMessages(_ loading: Bool) {
        isLoadingOlderMessages = loading
    }

    fileprivate func setError(_ error: String?) {
        self.error = error
    }

    fileprivate func beginRefresh() -> UInt64 {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    fileprivate func isCurrentRefresh(_ generation: UInt64) -> Bool {
        refreshGeneration == generation
    }
}

struct DashboardWorkspaceOverview: Equatable, Sendable {
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]

    init(_ workspace: WorkspaceSnapshot) {
        folders = workspace.folders
        conversations = workspace.conversations
        notes = workspace.notes
    }
}

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
        Self.latestEntries(from: try entries())
    }

    func compactToLatestEntries() throws {
        try withExclusiveLock {
            let latest = Self.latestEntries(from: try entriesUnlocked())
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

    private static func latestEntries(
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
                if let error = processJournaled(Self.latestEntries(from: entries)) {
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

    private static func latestEntries(
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

@MainActor
@Observable
final class ApplicationModel {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var localCLIAgents: [WorkspaceAgent] = []
    private(set) var buzzWorkspaceAgents: [WorkspaceAgent] = []
    private(set) var remoteWorkspaceAgents: [WorkspaceAgent] = []
    let remoteWorkspaces: RemoteWorkspacesModel
    private(set) var buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
        links: [],
        enrollments: []
    )
    private(set) var buzzWorkspaceCandidates: [
        UUID: [BuzzWorkspaceAgentCandidate]
    ] = [:]
    private(set) var launchableBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    private(set) var checkingBuzzWorkspaceLinkIDs: Set<UUID> = []
    private(set) var mutatingBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    private(set) var buzzWorkspaceError: String?
    private(set) var openClawGatewayLinks: [OpenClawGatewayLink] = []
    private(set) var openClawGatewayErrors: [UUID: String] = [:]
    private(set) var openClawGatewayNotices: [UUID: String] = [:]
    private(set) var openClawGatewayOperationAgentIDs: Set<UUID> = []
    private(set) var openClawGatewayOperationStatuses: [
        UUID: OpenClawGatewayConnectionStatus
    ] = [:]
    private(set) var pendingOpenClawGatewayAgentID: UUID?
    private(set) var openClawHeartbeatConfigurations: [UUID: OpenClawHeartbeatConfiguration] = [:]
    private(set) var openClawHeartbeatMessages: [UUID: String] = [:]
    private(set) var openClawHeartbeatErrorAgentIDs: Set<UUID> = []
    private(set) var openClawHeartbeatSavingAgentIDs: Set<UUID> = []
    private(set) var openClawGatewaySessionPreferences: [String: OpenClawSessionPreferences] = [:]
    private(set) var openClawGatewaySessionMetadata: [String: LocalACPSessionMetadata] = [:]
    private(set) var openClawCronJobs: [OpenClawCronJob] = []
    private(set) var openClawCronRuns: [OpenClawCronRun] = []
    private(set) var isRefreshingOpenClawCron = false
    private(set) var openClawCronError: String?
    private var openClawGatewayConversationIDs: Set<String> = []
    private var buzzBoundLocalACPConversationIDs: Set<String> = []
    private(set) var workspaceOverview: DashboardWorkspaceOverview?
    private(set) var calendarItems: [WorkspaceCalendarItemRecord] = []
    private(set) var workspaceRevision: Int64 = 0
    private(set) var workspaceListRevision: Int64 = 0
    private(set) var macSurfaceProfile: SurfaceProfile?
    private(set) var workspaceError: String?
    private(set) var newChatError: String?
    private(set) var folderMutationError: String?
    private(set) var noteMutationError: String?
    private(set) var noteEditingSocketPath: String?
    private(set) var calendarMutationError: String?
    private(set) var isCreatingCalendarItem = false
    private(set) var noteDrafts: [String: DashboardNoteDraft] = [:]
    private(set) var localACPSessionMetadata: [
        String: LocalACPSessionMetadata
    ] = [:]
    private var localACPSessionRefreshLifecycle = LocalACPSessionRefreshLifecycle()
    var loadingLocalACPSessionIDs: Set<String> {
        localACPSessionRefreshLifecycle.loadingConversationIDs
    }
    private(set) var updatingLocalACPSessionIDs: Set<String> = []
    private(set) var localRunError: String?
    private(set) var localACPRuntimeAvailability: [LocalACPRuntimeAvailability] = []
    private(set) var localACPDatabaseReadyRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var localACPAgentReconciliationError: String?
    private(set) var checkingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var localACPWorkspaceAvailability = LocalACPWorkspaceAvailability(
        state: .setupRequired,
        detail: "Set up the shared direct workspace before starting a chat.",
        rootPath: nil,
        repositoriesPath: nil,
        usesExternalRepositories: false
    )
    private(set) var databasesSnapshot = DashboardDatabasesSnapshot.empty
    private(set) var isRefreshingDatabases = false
    private(set) var databaseError: String?
    @ObservationIgnored
    private var databaseRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    private var databaseRefreshRequestedWhileRunning = false
    private(set) var titleGenerationSettings = ConversationTitleGenerationSettings(
        isEnabled: true,
        model: "",
        thinking: ""
    )
    private(set) var titleGenerationCapabilities: CodexTitleGenerationCapabilities?
    private(set) var titleGenerationStatus = "Waiting for Codex"
    private(set) var isRefreshingTitleGenerationCapabilities = false
    private(set) var installingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var preparedLocalACPRuntimeInstall:
        PreparedLocalACPRuntimeInstall?
    private(set) var pendingLocalACPPermissions: [PendingLocalACPPermission] = []
    private(set) var pendingLocalACPInteractions: [PendingLocalACPInteraction] = []
    private(set) var localRunningConversationIDs: Set<String> = []
    private(set) var conversationStatesByID: [String: DashboardConversationState] = [:]
    private(set) var localUsage: LocalUsageSnapshot?
    private(set) var localUsageError: String?
    private(set) var isRefreshingLocalUsage = false
    private(set) var isOpenRouterCredentialConfigured = false
    private(set) var signingInUsageProviders: Set<ProviderKind> = []

    private var dashboardStore: DashboardStore?
    private var noteWriteBehind: DashboardNoteWriteBehind?
    @ObservationIgnored
    private var noteEditingService: WovenNoteService?
    private var dashboardStoreStarted = false
    private var dashboardStoreStartDeferredForNoteRecovery = false
    private var startupTask: Task<Void, Never>?
    private var conversationChangeTask: Task<Void, Never>?
    private var conversationChangeWorkers: [String: Task<Void, Never>] = [:]
    private var conversationChangeWorkerTokens: [String: UUID] = [:]
    private var pendingConversationChanges: [String: [DashboardConversationChange]] = [:]
    private var terminalRunIDsByConversation: [String: String] = [:]
    private var localUsageRefreshGeneration: UInt64 = 0
    private var surfaceProfilePersistenceTask: Task<Void, Never>?
    private var surfaceProfilePersistenceGeneration = 0
    @ObservationIgnored
    private let localACPRuntimeResolver = LocalACPRuntimeResolver()
    @ObservationIgnored
    private let localUsageService = LocalUsageService()
    @ObservationIgnored
    private let applicationDefaults: UserDefaults
    @ObservationIgnored
    private let localACPWorkspaceStore: LocalACPWorkspaceConfigurationStore
    @ObservationIgnored
    private let localACPRuntimeInstaller = LocalACPRuntimeInstaller()
    @ObservationIgnored
    private let conversationTitleGenerator = CodexConversationTitleGenerator()
    @ObservationIgnored
    private var localACPLaunchConfigurations: [
        AgentRuntimeKind: LocalACPRuntimeLaunchConfiguration
    ] = [:]
    @ObservationIgnored
    private var localACPRuntimeRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var generatingConversationTitleIDs: Set<String> = []
    @ObservationIgnored
    private var localACPWorkspaceLaunchConfiguration:
        LocalACPWorkspaceLaunchConfiguration?
    @ObservationIgnored
    private var localACPPermissionContinuations: [
        UUID: CheckedContinuation<String?, Never>
    ] = [:]
    @ObservationIgnored
    private var localACPInteractionContinuations: [
        UUID: CheckedContinuation<LocalACPInteractionResponse, Never>
    ] = [:]
    private var loggedDashboardRecordCounts: DashboardRecordCounts?
    private var noteRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var conversationAccessSequence: UInt64 = 0
    private static let initialConversationMessageLimit = 40
    private static let olderConversationMessageLimit = 40
    private static let maximumRetainedConversationCount = 50
    static let maximumActiveTurnCount = 120
    private static let titleGenerationEnabledDefaultsKey =
        "wovenmatter.title-generation.enabled"
    private static let titleGenerationModelDefaultsKey =
        "wovenmatter.title-generation.model"
    private static let titleGenerationThinkingDefaultsKey =
        "wovenmatter.title-generation.thinking"
    private static let buzzDiscoveryEnabledDefaultsKey =
        "wovenmatter.buzz.discovery-enabled"
    private static let openRouterCredentialConfiguredDefaultsKey =
        "wovenmatter.openrouter-credential.configured"

    init(
        applicationDefaults: UserDefaults = .standard,
        dashboardStore: DashboardStore? = nil,
        startsAutomatically: Bool? = nil
    ) {
        self.applicationDefaults = applicationDefaults
        self.remoteWorkspaces = RemoteWorkspacesModel(defaults: applicationDefaults)
        self.localACPWorkspaceStore = LocalACPWorkspaceConfigurationStore()
        self.dashboardStore = dashboardStore
        isOpenRouterCredentialConfigured = applicationDefaults.bool(
            forKey: Self.openRouterCredentialConfiguredDefaultsKey
        )
        if applicationDefaults.object(
            forKey: Self.titleGenerationEnabledDefaultsKey
        ) == nil {
            applicationDefaults.set(
                true,
                forKey: Self.titleGenerationEnabledDefaultsKey
            )
        }
        titleGenerationSettings = ConversationTitleGenerationSettings(
            isEnabled: applicationDefaults.bool(
                forKey: Self.titleGenerationEnabledDefaultsKey
            ),
            model: applicationDefaults.string(
                forKey: Self.titleGenerationModelDefaultsKey
            ) ?? "",
            thinking: applicationDefaults.string(
                forKey: Self.titleGenerationThinkingDefaultsKey
            ) ?? ""
        )
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath")
        guard startsAutomatically ?? !isRunningTests else { return }
        startupTask = Task { await start() }
    }

    func conversationState(for id: String) -> DashboardConversationState? {
        conversationStatesByID[id]
    }

    func conversationError(for id: String) -> String? {
        conversationStatesByID[id]?.error
    }

    func retry() {
        state = .starting
        startupTask?.cancel()
        startupTask = Task { await start() }
    }

    private func start() async {
        do {
            conversationChangeTask?.cancel()
            for worker in conversationChangeWorkers.values { worker.cancel() }
            conversationChangeWorkers.removeAll()
            conversationChangeWorkerTokens.removeAll()
            pendingConversationChanges.removeAll()
            terminalRunIDsByConversation.removeAll()
            dashboardStoreStarted = false
            dashboardStoreStartDeferredForNoteRecovery = false
            let supportDirectory = try Self.dashboardSupportDirectory()
            NSLog(
                "Woven Matter dashboard database: %@",
                supportDirectory.appending(path: "workspace.sqlite").path
            )
            let dashboardStore = try DashboardStore(supportDirectory: supportDirectory)
            self.dashboardStore = dashboardStore
            try await dashboardStore.prepareLocalWorkspace()
            localACPDatabaseReadyRuntimeKinds = Set(
                LocalACPRuntimeCatalog.definitions.map(\.runtimeKind)
            )
            try await loadMacSurfaceProfile(using: dashboardStore)
            let journal = DashboardNoteDraftJournal(
                fileURL: supportDirectory.appending(path: "note-draft-journal.ndjson")
            )
            let recoveredEntries = try journal.latestEntries()
            let writeBehind = DashboardNoteWriteBehind(
                journal: journal,
                update: { [database = dashboardStore.database] entry in
                    try database.persistNoteDraft(
                        id: entry.noteID,
                        title: entry.title,
                        content: entry.content,
                        folderID: entry.folderID,
                        createdAt: entry.createdAt
                    )
                },
                completion: { [weak self] entry, result in
                    Task { @MainActor [weak self] in
                        self?.completeNoteWrite(entry, result: result)
                    }
                }
            )
            noteWriteBehind = writeBehind
            let noteSocketURL = supportDirectory.appending(path: "woven-note.sock")
            let noteEditingService = WovenNoteService(socketURL: noteSocketURL) {
                [weak self, dashboardStore] request in
                do {
                    guard await self?.flushNoteDrafts() == true else {
                        throw ApplicationModelError.noteDraftSaveFailed
                    }
                    let response = try await dashboardStore.handleNoteEditingRequest(request)
                    await self?.adoptNoteEditingResponse(response)
                    return response
                } catch {
                    return NoteEditingResponse(
                        success: false,
                        noteID: request.noteID,
                        error: error.localizedDescription
                    )
                }
            }
            try noteEditingService.start()
            self.noteEditingService = noteEditingService
            noteEditingSocketPath = noteSocketURL.path
            await refreshLocalACPWorkspace()
            await refreshBuzzWorkspaces()
            await refreshOpenClawGateways()
            await restoreOpenClawGatewayLinks()
            await refreshOpenClawCron()
            await refreshWorkspace()
            for entry in recoveredEntries {
                let note = workspaceOverview?.notes.first { $0.id == entry.noteID }
                noteDrafts[entry.noteID] = .recovered(from: entry, source: note)
            }
            do {
                try await writeBehind.replayAndFlush(recoveredEntries)
            } catch {
                dashboardStoreStartDeferredForNoteRecovery = true
                noteMutationError = error.localizedDescription
                for entry in recoveredEntries {
                    noteDrafts[entry.noteID]?.fail(error.localizedDescription)
                }
            }
            recoverPendingRemoteNoteEdits(store: dashboardStore)
            await refreshWorkspace()
            state = .ready
            startDashboardStoreIfReady()
            Task { [weak self] in
                await self?.refreshDatabases()
            }

            guard !Task.isCancelled else { return }
            refreshLocalACPRuntimesNow()
            await refreshWorkspace()
            await refreshLocalUsage(
                range: currentUsageRange,
                refreshLimits: false,
                reason: .startup
            )
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }


    func persistMacSurfaceProfileFromUserDefaults() {
        guard let current = macSurfaceProfile,
              let deviceID = current.deviceID else { return }
        let next = Self.surfaceProfile(
            deviceID: deviceID,
            id: current.id,
            userID: current.userID,
            localCLIAgentOrder: current.localCLIAgentOrder ?? [],
            revision: current.revision,
            createdAt: current.createdAt
        )
        scheduleMacSurfaceProfilePersistence(next)
    }

    private func scheduleMacSurfaceProfilePersistence(_ next: SurfaceProfile) {
        guard let dashboardStore, let current = macSurfaceProfile else { return }
        guard !Self.sameSurfacePreferences(current, next) else { return }
        macSurfaceProfile = next
        surfaceProfilePersistenceGeneration += 1
        let generation = surfaceProfilePersistenceGeneration
        surfaceProfilePersistenceTask?.cancel()
        surfaceProfilePersistenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                let updated = try await dashboardStore.updateMacSurfaceProfile(next)
                guard generation == surfaceProfilePersistenceGeneration else { return }
                macSurfaceProfile = updated
                Self.cacheSurfaceProfile(updated)
            } catch is CancellationError {
                return
            } catch {
                guard generation == surfaceProfilePersistenceGeneration else { return }
                macSurfaceProfile = current
                NSLog("Could not persist Mac surface profile: %@", error.localizedDescription)
            }
        }
    }

    private func loadMacSurfaceProfile(using store: DashboardStore) async throws {
        let deviceID = try await store.dashboardDeviceID()
        let bootstrap = Self.surfaceProfile(deviceID: deviceID)
        let profile = try await store.macSurfaceProfile(bootstrap: bootstrap)
        macSurfaceProfile = profile
        Self.cacheSurfaceProfile(profile)
    }

    private static func surfaceProfile(
        deviceID: UUID,
        id: String? = nil,
        userID: String = "local-operator",
        localCLIAgentOrder: [UUID] = [],
        revision: Int64 = 1,
        createdAt: Date = Date()
    ) -> SurfaceProfile {
        let defaults = UserDefaults.standard
        func string(_ key: String, fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }
        func bool(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func double(_ key: String, fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        return SurfaceProfile(
            id: id ?? SurfaceProfile.macID(deviceID: deviceID),
            userID: userID,
            surface: .mac,
            deviceID: deviceID,
            theme: string(DashboardTheme.storageKey, fallback: DashboardTheme.green.rawValue),
            sidebarStyle: string(
                DashboardSidebarStyle.storageKey,
                fallback: DashboardSidebarStyle.defaultStyle.rawValue
            ),
            singleSidebarSide: string(
                DashboardSidebarSide.storageKey,
                fallback: DashboardSidebarSide.defaultSide.rawValue
            ),
            leftRailVisible: bool("wovenmatter.dashboard.left-rail", fallback: true),
            rightRailVisible: bool("wovenmatter.dashboard.right-rail", fallback: true),
            singleRailVisible: bool("wovenmatter.dashboard.single-rail", fallback: true),
            chatWidthPercent: double(
                "wovenmatter.dashboard.chat-width-percent",
                fallback: 58
            ),
            noteOnLeft: bool("wovenmatter.dashboard.note-on-left", fallback: false),
            workspaceMode: string(
                "wovenmatter.dashboard.workspace-mode",
                fallback: "chats"
            ),
            localCLIAgentOrder: localCLIAgentOrder,
            revision: revision,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    private static func cacheSurfaceProfile(_ profile: SurfaceProfile) {
        let defaults = UserDefaults.standard
        defaults.set(profile.theme, forKey: DashboardTheme.storageKey)
        defaults.set(profile.sidebarStyle, forKey: DashboardSidebarStyle.storageKey)
        defaults.set(profile.singleSidebarSide, forKey: DashboardSidebarSide.storageKey)
        defaults.set(profile.leftRailVisible, forKey: "wovenmatter.dashboard.left-rail")
        defaults.set(profile.rightRailVisible, forKey: "wovenmatter.dashboard.right-rail")
        defaults.set(profile.singleRailVisible, forKey: "wovenmatter.dashboard.single-rail")
        defaults.set(profile.chatWidthPercent, forKey: "wovenmatter.dashboard.chat-width-percent")
        defaults.set(profile.noteOnLeft, forKey: "wovenmatter.dashboard.note-on-left")
        defaults.set(profile.workspaceMode, forKey: "wovenmatter.dashboard.workspace-mode")
    }

    private static func sameSurfacePreferences(
        _ lhs: SurfaceProfile,
        _ rhs: SurfaceProfile
    ) -> Bool {
        lhs.theme == rhs.theme
            && lhs.sidebarStyle == rhs.sidebarStyle
            && lhs.singleSidebarSide == rhs.singleSidebarSide
            && lhs.leftRailVisible == rhs.leftRailVisible
            && lhs.rightRailVisible == rhs.rightRailVisible
            && lhs.singleRailVisible == rhs.singleRailVisible
            && lhs.chatWidthPercent == rhs.chatWidthPercent
            && lhs.noteOnLeft == rhs.noteOnLeft
            && lhs.workspaceMode == rhs.workspaceMode
            && (lhs.localCLIAgentOrder ?? []) == (rhs.localCLIAgentOrder ?? [])
    }

    var orderedLocalCLIAgents: [WorkspaceAgent] {
        Self.orderLocalCLIAgents(
            localCLIAgents,
            preferredOrder: macSurfaceProfile?.localCLIAgentOrder ?? []
        )
    }

    var orderedLocalACPRuntimeDefinitions: [LocalACPRuntimeDefinition] {
        Self.orderLocalACPRuntimeDefinitions(
            LocalACPRuntimeCatalog.definitions,
            agents: localCLIAgents,
            preferredOrder: macSurfaceProfile?.localCLIAgentOrder ?? []
        )
    }

    static func orderLocalACPRuntimeDefinitions(
        _ definitions: [LocalACPRuntimeDefinition],
        agents: [WorkspaceAgent],
        preferredOrder: [UUID]
    ) -> [LocalACPRuntimeDefinition] {
        let preferredRanks = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) }
        )
        var preferredRankByRuntime: [AgentRuntimeKind: Int] = [:]
        for agent in agents {
            guard let rank = preferredRanks[agent.id] else { continue }
            preferredRankByRuntime[agent.runtimeKind] = min(
                preferredRankByRuntime[agent.runtimeKind] ?? rank,
                rank
            )
        }
        return definitions.sorted { lhs, rhs in
            let lhsRank = preferredRankByRuntime[lhs.runtimeKind]
            let rhsRank = preferredRankByRuntime[rhs.runtimeKind]
            switch (lhsRank, rhsRank) {
            case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                )
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.runtimeKind.rawValue < rhs.runtimeKind.rawValue
            }
        }
    }

    static func orderLocalCLIAgents(
        _ agents: [WorkspaceAgent],
        preferredOrder: [UUID]
    ) -> [WorkspaceAgent] {
        let preferredRanks = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return agents.sorted { lhs, rhs in
            switch (preferredRanks[lhs.id], preferredRanks[rhs.id]) {
            case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                )
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    func isLocalACPAgentReady(_ runtimeKind: AgentRuntimeKind) -> Bool {
        localACPDatabaseReadyRuntimeKinds.contains(runtimeKind)
    }

    private func startDashboardStoreIfReady() {
        guard !dashboardStoreStarted,
              !dashboardStoreStartDeferredForNoteRecovery,
              let dashboardStore else { return }
        dashboardStoreStarted = true
        conversationChangeTask?.cancel()
        let changes = dashboardStore.conversationChanges
        conversationChangeTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                self?.enqueueConversationChange(change)
            }
        }
        Task { await dashboardStore.start() }
    }

    private func enqueueConversationChange(
        _ change: DashboardConversationChange
    ) {
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] == change.runID {
            return
        }
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] != change.runID {
            terminalRunIDsByConversation.removeValue(
                forKey: change.conversationID
            )
        }
        var pending = pendingConversationChanges[change.conversationID] ?? []
        if let last = pending.last, last.runID == change.runID {
            if last.phase == .terminal { return }
            pending[pending.count - 1] = change
        } else {
            pending.append(change)
        }
        pendingConversationChanges[change.conversationID] = pending
        guard conversationChangeWorkers[change.conversationID] == nil else {
            return
        }
        let conversationID = change.conversationID
        let token = UUID()
        conversationChangeWorkerTokens[conversationID] = token
        conversationChangeWorkers[conversationID] = Task { [weak self] in
            await self?.drainConversationChanges(
                conversationID: conversationID,
                token: token
            )
        }
    }

    private func drainConversationChanges(
        conversationID: String,
        token: UUID
    ) async {
        while !Task.isCancelled,
              var pending = pendingConversationChanges[conversationID],
              !pending.isEmpty {
            let change = pending.removeFirst()
            if pending.isEmpty {
                pendingConversationChanges.removeValue(forKey: conversationID)
            } else {
                pendingConversationChanges[conversationID] = pending
            }
            if change.phase == .content,
               terminalRunIDsByConversation[conversationID] == change.runID {
                continue
            }
            await applyConversationChange(change)
            if change.phase == .terminal {
                terminalRunIDsByConversation[conversationID] = change.runID
            }
        }
        guard conversationChangeWorkerTokens[conversationID] == token else {
            return
        }
        conversationChangeWorkers.removeValue(forKey: conversationID)
        conversationChangeWorkerTokens.removeValue(forKey: conversationID)
    }

    private func applyConversationChange(
        _ change: DashboardConversationChange
    ) async {
        await refreshConversation(id: change.conversationID)
        guard change.phase == .terminal else { return }
        if let dashboardStore {
            recoverPendingRemoteNoteEdit(
                runID: change.runID,
                conversationID: change.conversationID,
                store: dashboardStore
            )
        }
        await refreshWorkspaceIfChanged()
        finishAgentRunInteractions(conversationID: change.conversationID)
        trimConversationStateCacheIfNeeded()
        if let conversation = workspaceOverview?.conversations.first(where: {
            $0.id == change.conversationID
        }) {
            if openClawGatewayConversationIDs.contains(change.conversationID) {
                await refreshOpenClawGatewaySession(
                    conversationID: change.conversationID
                )
            } else if conversation.localRuntimeKind != nil {
                await refreshLocalACPSession(conversation: conversation)
            }
        }
        await refreshLocalUsage(
            range: currentUsageRange,
            refreshLimits: false,
            reason: .runCompleted
        )
    }

    private func recoverPendingRemoteNoteEdit(
        runID: String,
        conversationID: String,
        store: DashboardStore
    ) {
        guard flushNoteDrafts() else { return }
        guard let pending = (try? store.database.pendingRemoteNoteEdits())?
            .first(where: { $0.runID == runID }) else {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            return
        }
        do {
            if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                if adoptNoteEditingResponseDraft(response) {
                    Task { await refreshWorkspace() }
                }
            }
        } catch {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            ensureConversationState(id: conversationID).setError(
                "The agent response was saved, but its note edit was not applied: \(error.localizedDescription)"
            )
        }
    }

    private static func dashboardSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationModelError.applicationSupportUnavailable
        }
        return applicationSupport.appending(path: "Woven Matter", directoryHint: .isDirectory)
    }

    func refreshWorkspace() async {
        await refreshWorkspace(force: true)
    }

    private func refreshWorkspaceIfChanged() async {
        await refreshWorkspace(force: false)
    }

    private func refreshWorkspace(force: Bool) async {
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let priorRevision = force || workspaceOverview == nil ? nil : workspaceRevision
            if let snapshot = try await dashboardStore.snapshot(ifChangedFrom: priorRevision) {
                apply(snapshot)
            }
            let reconciledRunning = try await dashboardStore
                .activeAgentConversationIDs()
            if localRunningConversationIDs != reconciledRunning {
                localRunningConversationIDs = reconciledRunning
                trimConversationStateCacheIfNeeded()
            }
            if workspaceError != nil {
                workspaceError = nil
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func refreshConversation(id: String) async {
        let state = ensureConversationState(id: id)
        let generation = state.beginRefresh()
        do {
            guard let dashboardStore else { return }
            let page = try await dashboardStore.conversationHistoryPage(
                id: id,
                limit: Self.initialConversationMessageLimit
            )
            guard !Task.isCancelled, page.conversationID == id else { return }
            let previous = state.presentation
            let renderTask = Task.detached(priority: .userInitiated) { () -> DashboardConversationPresentation? in
                let window = previous?.window.refreshing(with: page)
                    ?? DashboardConversationWindow(page: page)
                guard previous?.window != window else { return nil }
                let messagesByID: [String: DashboardMessagePresentation]
                let runsByID: [String: DashboardRunPresentation]
                if let previous, previous.window.loadedOlderMessages {
                    var nextMessages = previous.messagesByID
                    for (messageID, presentation) in Self.renderMessagePresentations(
                        page.messages,
                        reusing: previous.messagesByID
                    ) {
                        nextMessages[messageID] = presentation
                    }
                    messagesByID = nextMessages
                    var nextRuns = previous.runsByID
                    for (runID, presentation) in Self.renderRunPresentations(
                        page.runs,
                        reusing: previous.runsByID
                    ) {
                        nextRuns[runID] = presentation
                    }
                    runsByID = nextRuns
                } else {
                    messagesByID = Self.renderMessagePresentations(
                        page.messages,
                        reusing: previous?.messagesByID ?? [:]
                    )
                    runsByID = Self.renderRunPresentations(
                        page.runs,
                        reusing: previous?.runsByID ?? [:]
                    )
                }
                return DashboardConversationPresentation(
                    window: window,
                    messagesByID: messagesByID,
                    runsByID: runsByID
                )
            }
            let presentation = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled else { return }
            guard conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            if let presentation { state.apply(presentation) }
            touchConversationState(state)
            state.setError(nil)
            workspaceError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            state.setError(error.localizedDescription)
        }
    }

    @discardableResult
    func loadOlderConversationMessages(id: String) async -> Bool {
        guard let state = conversationStatesByID[id],
              !state.isLoadingOlderMessages,
              let current = state.presentation,
              current.window.conversationID == id,
              current.window.hasOlderMessages,
              let cursor = current.window.messages.first.map({
                  WorkspaceConversationHistoryCursor(createdAt: $0.createdAt, messageID: $0.id)
              }),
              let dashboardStore else {
            return false
        }
        state.setLoadingOlderMessages(true)
        defer { state.setLoadingOlderMessages(false) }
        do {
            let page = try await dashboardStore.conversationHistoryPage(
                id: id,
                before: cursor,
                limit: Self.olderConversationMessageLimit
            )
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state else {
                return false
            }
            let renderTask = Task.detached(priority: .userInitiated) {
                let messagesByID = Self.renderMessagePresentations(
                    page.messages,
                    reusing: current.messagesByID
                )
                let runsByID = Self.renderRunPresentations(
                    page.runs,
                    reusing: current.runsByID
                )
                return (messages: messagesByID, runs: runsByID)
            }
            let renderedPage = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled,
                  let latest = state.presentation,
                  latest.window.conversationID == id else {
                return false
            }
            var messagesByID = renderedPage.messages
            for (messageID, presentation) in current.messagesByID {
                messagesByID[messageID] = presentation
            }
            for (messageID, presentation) in latest.messagesByID {
                messagesByID[messageID] = presentation
            }
            var runsByID = renderedPage.runs
            for (runID, presentation) in current.runsByID {
                runsByID[runID] = presentation
            }
            for (runID, presentation) in latest.runsByID {
                runsByID[runID] = presentation
            }
            let expandedWindow = current.window.prepending(page)
            state.apply(DashboardConversationPresentation(
                window: expandedWindow.mergingNewer(latest.window),
                messagesByID: messagesByID,
                runsByID: runsByID
            ))
            touchConversationState(state)
            workspaceError = nil
            return page.messages.isEmpty == false
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            state.setError(error.localizedDescription)
            return false
        }
    }

    private func ensureConversationState(id: String) -> DashboardConversationState {
        if let state = conversationStatesByID[id] {
            touchConversationState(state)
            return state
        }
        let state = DashboardConversationState(conversationID: id)
        touchConversationState(state)
        conversationStatesByID[id] = state
        trimConversationStateCacheIfNeeded()
        return state
    }

    private func touchConversationState(_ state: DashboardConversationState) {
        conversationAccessSequence &+= 1
        state.lastAccessSequence = conversationAccessSequence
    }

    private func trimConversationStateCacheIfNeeded() {
        let inactive = conversationStatesByID.values
            .filter {
                !localRunningConversationIDs.contains($0.conversationID)
                    && !$0.isLoadingOlderMessages
            }
            .sorted { $0.lastAccessSequence < $1.lastAccessSequence }
        guard inactive.count > Self.maximumRetainedConversationCount else { return }
        for state in inactive.prefix(
            inactive.count - Self.maximumRetainedConversationCount
        ) {
            conversationStatesByID.removeValue(forKey: state.conversationID)
        }
    }

    private nonisolated static func renderMessagePresentations(
        _ messages: [WorkspaceMessageRecord],
        reusing previous: [String: DashboardMessagePresentation]
    ) -> [String: DashboardMessagePresentation] {
        var result: [String: DashboardMessagePresentation] = [:]
        result.reserveCapacity(messages.count)
        for message in messages {
            guard !Task.isCancelled else { return result }
            if let existing = previous[message.id],
               existing.source == message.content,
               existing.status == message.status,
               existing.createdAt == message.createdAt {
                result[message.id] = existing
                continue
            }
            result[message.id] = DashboardMessagePresentation(
                source: message.content,
                status: message.status,
                createdAt: message.createdAt,
                document: message.role == "assistant"
                    ? ConversationMarkdownDocument(
                        RemoteNoteEditEnvelope.redactingEnvelopes(in: message.content)
                    )
                    : nil
            )
        }
        return result
    }

    private nonisolated static func renderRunPresentations(
        _ runs: [WorkspaceRunRecord],
        reusing previous: [String: DashboardRunPresentation]
    ) -> [String: DashboardRunPresentation] {
        var result: [String: DashboardRunPresentation] = [:]
        result.reserveCapacity(runs.count)
        for run in runs {
            guard !Task.isCancelled else { return result }
            if let existing = previous[run.id], existing.source == run {
                result[run.id] = existing
                continue
            }
            let startedAt = (run.startedAt ?? run.createdAt).flatMap(dashboardParsedDate)
            let completedDuration: String?
            if run.status != "running",
               let startedAt,
               let endValue = run.completedAt ?? run.updatedAt,
               let completedAt = dashboardParsedDate(endValue) {
                completedDuration = dashboardRunDuration(completedAt.timeIntervalSince(startedAt))
            } else {
                completedDuration = nil
            }
            result[run.id] = DashboardRunPresentation(
                source: run,
                startedAt: startedAt,
                completedDuration: completedDuration
            )
        }
        return result
    }

    func markConversationRead(id: String) {
        guard workspaceOverview?.conversations.first(where: { $0.id == id })?.unread == true else { return }
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.markConversationRead(id: id)
                await refreshWorkspace()
            } catch {
                workspaceError = error.localizedDescription
            }
        }
    }

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

    private func adoptNoteEditingResponse(_ response: NoteEditingResponse) async {
        guard adoptNoteEditingResponseDraft(response) else { return }
        await refreshWorkspace()
    }

    @discardableResult
    private func adoptNoteEditingResponseDraft(_ response: NoteEditingResponse) -> Bool {
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

    private func persistNoteDraft(
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

    private func completeNoteWrite(
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
            if noteWriteBehind?.hasOutstandingWork() == false {
                noteMutationError = nil
            }
            noteDrafts[entry.noteID] = draft
            if dashboardStoreStartDeferredForNoteRecovery,
               noteWriteBehind?.hasOutstandingWork() == false {
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

    func refreshLocalUsage(
        range: UsageTimeRange,
        refreshLimits: Bool = false,
        reason: UsageRefreshReason = .manual
    ) async {
        localUsageRefreshGeneration &+= 1
        let generation = localUsageRefreshGeneration
        isRefreshingLocalUsage = true
        localUsageError = nil
        let snapshot = await localUsageService.snapshot(
            range: range,
            refreshLimits: refreshLimits,
            refreshReason: reason,
            allowCredentialAccess: isOpenRouterCredentialConfigured
                && (reason == .manual || reason == .credentialChanged)
        )
        guard generation == localUsageRefreshGeneration else { return }
        isRefreshingLocalUsage = false
        guard !Task.isCancelled else { return }
        localUsage = snapshot
    }

    private var currentUsageRange: UsageTimeRange {
        let rawValue = UserDefaults.standard.string(
            forKey: "wovenmatter.usage.range"
        )
        return rawValue.flatMap(UsageTimeRange.init(rawValue:)) ?? .last30Days
    }

    func saveOpenRouterAPIKey(_ value: String, range: UsageTimeRange) async {
        do {
            try await localUsageService.saveOpenRouterAPIKey(value)
            isOpenRouterCredentialConfigured = true
            applicationDefaults.set(
                true,
                forKey: Self.openRouterCredentialConfiguredDefaultsKey
            )
            await refreshLocalUsage(
                range: range,
                refreshLimits: true,
                reason: .credentialChanged
            )
        } catch {
            localUsageError = error.localizedDescription
        }
    }

    func deleteOpenRouterAPIKey(range: UsageTimeRange) async {
        do {
            try await localUsageService.deleteOpenRouterAPIKey()
            isOpenRouterCredentialConfigured = false
            applicationDefaults.set(
                false,
                forKey: Self.openRouterCredentialConfiguredDefaultsKey
            )
            await refreshLocalUsage(
                range: range,
                refreshLimits: true,
                reason: .credentialChanged
            )
        } catch {
            localUsageError = error.localizedDescription
        }
    }

    func signInUsageProvider(_ provider: ProviderKind) {
        guard !signingInUsageProviders.contains(provider) else { return }
        guard let command = Self.usageProviderSignInCommand(provider) else {
            localUsageError = "\(provider.displayName) sign-in is unavailable because its CLI is not installed."
            return
        }
        signingInUsageProviders.insert(provider)
        localUsageError = nil
        Task {
            defer { signingInUsageProviders.remove(provider) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = command.executable
                    process.arguments = command.arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw UsageProviderSignInError.failed(
                            provider.displayName,
                            process.terminationStatus
                        )
                    }
                }.value
                await refreshLocalUsage(
                    range: currentUsageRange,
                    refreshLimits: true,
                    reason: .viewAppeared
                )
            } catch {
                localUsageError = error.localizedDescription
            }
        }
    }

    private nonisolated static func usageProviderSignInCommand(
        _ provider: ProviderKind
    ) -> UsageProviderSignInCommand? {
        let executableName: String
        let arguments: [String]
        switch provider {
        case .codex:
            executableName = "codex"
            arguments = ["login"]
        case .claude:
            executableName = "claude"
            arguments = ["auth", "login", "--claudeai"]
        case .grok:
            executableName = "grok"
            arguments = ["login", "--oauth"]
        case .cursor:
            executableName = LocalACPRuntimeResolver.resolveExecutable(
                named: "cursor-agent"
            ) == nil ? "agent" : "cursor-agent"
            arguments = ["login"]
        case .openCodeGo:
            executableName = "opencode"
            arguments = ["auth", "login", "--provider", "opencode-go"]
        case .openRouter, .unknown:
            return nil
        }
        guard let executable = LocalACPRuntimeResolver.resolveExecutable(
            named: executableName
        ) else { return nil }
        return UsageProviderSignInCommand(
            executable: executable,
            arguments: arguments
        )
    }

    private struct AgentNoteBinding {
        enum Transport {
            case local(environment: [String: String])
            case mediated(nonce: String, structureJSON: String)
        }

        let context: AgentNoteContext
        let kind: NoteArtifactKind
        let transport: Transport
    }

    private func makeAgentNoteBinding(
        _ note: WorkspaceNoteRecord?,
        store: DashboardStore,
        mediated: Bool
    ) async throws -> AgentNoteBinding? {
        guard let note else { return nil }
        guard flushNoteDrafts() else {
            throw ApplicationModelError.noteDraftSaveFailed
        }
        let response = try await store.handleNoteEditingRequest(
            NoteEditingRequest(command: .read, noteID: note.id)
        )
        guard response.success,
              let title = response.title,
              let revision = response.revision,
              let document = response.document else {
            throw ApplicationModelError.noteContextUnavailable
        }
        let transport: AgentNoteBinding.Transport
        let remoteNonce: String?
        if mediated {
            let nonce = UUID().uuidString.lowercased()
            remoteNonce = nonce
            transport = .mediated(
                nonce: nonce,
                structureJSON: Self.redactedNoteStructure(document)
            )
        } else {
            remoteNonce = nil
            let environment = noteCLIEnvironment(noteID: note.id)
            guard environment["WOVEN_NOTE_CLI"] != nil,
                  environment["WOVEN_NOTE_SOCKET"] != nil else {
                throw ApplicationModelError.noteContextUnavailable
            }
            transport = .local(environment: environment)
        }
        return AgentNoteBinding(
            context: AgentNoteContext(
                noteID: note.id,
                title: title,
                folderID: note.folderID,
                revision: revision,
                remoteEditNonce: remoteNonce,
                artifactKind: mediated ? document.kind : nil
            ),
            kind: document.kind,
            transport: transport
        )
    }

    private func noteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding?
    ) -> String {
        guard let binding else { return content }
        switch binding.transport {
        case .local(let environment):
            return localNoteAwarePrompt(content, binding: binding, environment: environment)
        case .mediated(let nonce, let structureJSON):
            return mediatedNoteAwarePrompt(
                content,
                binding: binding,
                nonce: nonce,
                structureJSON: structureJSON
            )
        }
    }

    private func localNoteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding,
        environment: [String: String]
    ) -> String {
        let exports = [
            "WOVEN_NOTE_CLI",
            "WOVEN_NOTE_SOCKET",
            "WOVEN_NOTE_ID",
            "WOVEN_DATABASES_DIR",
        ]
            .compactMap { key in
                environment[key].map { "export \(key)=\(Self.shellQuote($0))" }
            }
            .joined(separator: "\n")
        let editingGuidance: String
        switch binding.kind {
        case .note:
            editingGuidance = """
            This is a regular note. Preserve its prose. Databases attach to individual tables:
            "$WOVEN_NOTE_CLI" append --text "Text" --revision REVISION
            "$WOVEN_NOTE_CLI" table create --rows 3 --columns 3 --header --revision REVISION
            "$WOVEN_NOTE_CLI" table set-cell --table-id TABLE_ID --row 0 --column 0 --text "Value" --revision REVISION
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --table-id TABLE_ID --revision REVISION
            """
        case .spreadsheet:
            editingGuidance = """
            This note is an editable spreadsheet. Read it to obtain its table ID, then use table operations to populate cells. The whole spreadsheet may link to database data:
            "$WOVEN_NOTE_CLI" table set-cell --table-id TABLE_ID --row 0 --column 0 --text "Value" --revision REVISION
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --revision REVISION
            """
        case .html:
            editingGuidance = """
            This note is an HTML artifact. The user owns its title; render the artifact body with:
            "$WOVEN_NOTE_CLI" set-html --file artifact.html --revision REVISION
            Link database data with:
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --revision REVISION
            Linked JSON is available to the rendered page as window.wovenMatterData.
            """
        }
        return """
        \(content)

        <woven-matter-note>
        The open Woven Matter note "\(binding.context.title)" is attached to this run. You may read and edit it with the local CLI. Use the current revision returned by `read` when applying related changes. Changes appear immediately in the open editor.

        \(exports)
        "$WOVEN_NOTE_CLI" read

        \(editingGuidance)
        "$WOVEN_NOTE_CLI" apply --file operations.json --revision REVISION
        Read the artifact first, preserve unrelated content, and use the CLI rather than editing Woven Matter's SQLite store directly. Database folders themselves are available under "$WOVEN_DATABASES_DIR".
        </woven-matter-note>
        """
    }

    private func mediatedNoteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding,
        nonce: String,
        structureJSON: String
    ) -> String {
        let begin = RemoteNoteEditEnvelope.beginMarker(nonce: nonce)
        let end = RemoteNoteEditEnvelope.endMarker(nonce: nonce)
        let kindGuidance: String
        switch binding.kind {
        case .note:
            kindGuidance = "Preserve prose. Database links belong on individual tables."
        case .spreadsheet:
            kindGuidance = "Edit cells using the table ID below; an artifact-level database link is allowed."
        case .html:
            kindGuidance = "The user owns the title. You may replace the HTML body and set an artifact-level database link, but must not emit setTitle."
        }
        return """
        \(content)

        <woven-matter-note>
        The open Woven Matter \(binding.kind.displayName.lowercased()) "\(binding.context.title)" is attached to this remote run. \(kindGuidance)
        For privacy, only its structural map is attached; existing prose, cell values, and HTML are not sent:
        \(structureJSON)

        If and only if you want to edit the artifact, append exactly one revision-checked JSON envelope after your normal response, without a Markdown code fence:
        \(begin)
        {"version":1,"nonce":"\(nonce)","noteID":"\(binding.context.noteID)","expectedRevision":"\(binding.context.revision)","operations":[{"type":"appendText","text":"Example","style":"paragraph"}]}
        \(end)
        Use only NoteEditOperation JSON. The envelope is limited to 1 MiB and 128 operations. Woven Matter applies it only after this run completes successfully and only if the note revision still matches. Never attempt to access Woven Matter's SQLite store directly.
        </woven-matter-note>
        """
    }

    private nonisolated static func redactedNoteStructure(_ document: NoteDocument) -> String {
        let blocks: [[String: Any]] = document.blocks.map { block in
            switch block {
            case .richText(let richText):
                return [
                    "id": richText.id,
                    "type": "richText",
                    "style": richText.style.rawValue,
                ]
            case .table(let table):
                return [
                    "id": table.id,
                    "type": "table",
                    "rows": table.rows.count,
                    "columns": table.columns.count,
                    "headerRows": table.headerRowCount,
                ]
            }
        }
        let object: [String: Any] = [
            "version": NoteDocument.currentVersion,
            "kind": document.kind.rawValue,
            "blocks": blocks,
            "hasArtifactDatabaseLink": document.databaseLink != nil,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        content: String,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        await sendAgentMessage(
            conversation: conversation,
            input: AgentMessageInput(text: content),
            note: note
        )
    }

    func stageMessageAttachments(
        _ files: [(url: URL, mimeType: String)]
    ) async throws -> [AgentMessageAttachmentDraft] {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        var staged: [AgentMessageAttachmentDraft] = []
        for file in files {
            staged.append(try await dashboardStore.stageMessageAttachment(
                fileURL: file.url,
                mimeType: file.mimeType
            ))
        }
        return staged
    }

    func noteAttachmentDraft(_ note: WorkspaceNoteRecord) -> AgentMessageAttachmentDraft {
        let folder = note.folderID.flatMap { folderID in
            workspaceOverview?.folders.first(where: { $0.id == folderID })
        }
        return .reference(AgentMessageReferenceDraft(
            kind: .note,
            resourceID: note.id,
            titleSnapshot: note.title,
            contentSnapshot: String(note.content.prefix(AgentMessageAttachmentLimits.maximumReferenceCharacters)),
            revisionSnapshot: note.updatedAt ?? note.createdAt ?? "",
            folderIDSnapshot: note.folderID,
            folderTitleSnapshot: folder?.name
        ))
    }

    func conversationAttachmentDraft(
        _ conversation: WorkspaceConversationRecord
    ) async throws -> AgentMessageAttachmentDraft {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        let content = try await dashboardStore.conversationContent(id: conversation.id)
        let transcript = content.messages.map { message in
            let value = message.role == "assistant"
                ? RemoteNoteEditEnvelope.redactingEnvelopes(in: message.content)
                : message.content
            return "\(message.role.capitalized): \(value)"
        }.joined(separator: "\n\n")
        return .reference(AgentMessageReferenceDraft(
            kind: .conversation,
            resourceID: conversation.id,
            titleSnapshot: conversation.title,
            contentSnapshot: String(transcript.prefix(AgentMessageAttachmentLimits.maximumReferenceCharacters)),
            revisionSnapshot: conversation.lastMessageAt ?? "",
            folderIDSnapshot: conversation.folderID,
            folderTitleSnapshot: conversation.folderID.flatMap { folderID in
                workspaceOverview?.folders.first(where: { $0.id == folderID })?.name
            },
            agentCodenameSnapshot: conversation.agentCodename
        ))
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        let conversationState = ensureConversationState(id: conversation.id)
        let normalized = AgentMessageInput(
            text: input.text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: input.attachments
        )
        guard normalized.hasContent, let dashboardStore else {
            conversationState.setError(
                ApplicationModelError.localACPRuntimeUnavailable.localizedDescription
            )
            return false
        }
        guard !loadingLocalACPSessionIDs.contains(conversation.id),
              !updatingLocalACPSessionIDs.contains(conversation.id) else {
            conversationState.setError(
                ApplicationModelError.localSessionConfigurationInProgress
                    .localizedDescription
            )
            return false
        }
        let isSteeringActiveTurn = localRunningConversationIDs.contains(
            conversation.id
        )
        if !isSteeringActiveTurn {
            guard localRunningConversationIDs.count
                    < Self.maximumActiveTurnCount else {
                conversationState.setError(
                    ApplicationModelError.activeTurnLimitReached.localizedDescription
                )
                return false
            }
            localRunningConversationIDs.insert(conversation.id)
        }

        conversationState.setError(nil)
        localRunError = nil
        do {
            let usesOpenClawGateway = try await shouldUseOpenClawGateway(
                for: conversation
            )
            let usesMediatedNoteEditing = usesOpenClawGateway
            let noteBinding = canAgentEditOpenNote(conversation)
                && !(isSteeringActiveTurn && usesMediatedNoteEditing)
                ? try await makeAgentNoteBinding(
                    note,
                    store: dashboardStore,
                    mediated: usesMediatedNoteEditing
                ) : nil
            let deliveryContent = noteAwarePrompt(
                normalized.text,
                binding: noteBinding
            )
            if isSteeringActiveTurn {
                if usesOpenClawGateway {
                    do {
                        _ = try await dashboardStore.sendActiveOpenClawGatewayPrompt(
                            conversationID: conversation.id,
                            input: normalized,
                            deliveryContent: deliveryContent
                        )
                    } catch LocalACPSessionDatabaseError.steeringUnsupported {
                        throw ApplicationModelError.steeringUnavailable
                    }
                    return true
                }
                do {
                    _ = try await dashboardStore.sendActiveLocalACPPrompt(
                        conversationID: conversation.id,
                        input: normalized,
                        deliveryContent: deliveryContent
                    )
                } catch LocalACPSessionDatabaseError.steeringUnsupported {
                    throw ApplicationModelError.steeringUnavailable
                }
                return true
            }
            let accepted: LocalACPRunIdentifiers
            if usesOpenClawGateway {
                accepted = try await acceptOpenClawGatewayMessage(
                    conversation: conversation,
                    input: normalized,
                    deliveryContent: deliveryContent,
                    noteContext: noteBinding?.context,
                    store: dashboardStore
                )
            } else {
                accepted = try await acceptLocalAgentMessage(
                    conversation: conversation,
                    input: normalized,
                    deliveryContent: deliveryContent,
                    noteContext: noteBinding?.context,
                    store: dashboardStore
                )
            }
            scheduleConversationTitleGeneration(
                conversation: conversation,
                firstPrompt: normalized.previewText
            )
            _ = accepted
            return true
        } catch {
            if !isSteeringActiveTurn {
                localRunningConversationIDs.remove(conversation.id)
            }
            await refreshWorkspaceIfChanged()
            await refreshConversation(id: conversation.id)
            conversationState.setError(error.localizedDescription)
            return false
        }
    }

    private func processPendingRemoteNoteEdit(
        _ pending: PendingRemoteNoteEdit,
        store: DashboardStore
    ) throws -> NoteEditingResponse? {
        guard let envelope = try RemoteNoteEditEnvelope.extract(
            from: pending.assistantContent,
            nonce: pending.nonce,
            noteID: pending.noteID,
            expectedRevision: pending.expectedRevision,
            noteKind: pending.noteKind
        ) else {
            try store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
            return nil
        }
        let current = try store.database.readNoteForEditing(id: pending.noteID)
        guard current.success, let document = current.document else {
            throw ApplicationModelError.noteContextUnavailable
        }
        try envelope.validateApplying(to: document)
        return try store.database.applyPendingRemoteNoteEdit(
            pending,
            envelope: envelope,
            visibleAssistantContent: RemoteNoteEditEnvelope.redactingEnvelopes(
                in: pending.assistantContent
            )
        )
    }

    private func recoverPendingRemoteNoteEdits(store: DashboardStore) {
        guard flushNoteDrafts() else { return }
        for pending in (try? store.database.pendingRemoteNoteEdits()) ?? [] {
            do {
                if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                    if adoptNoteEditingResponseDraft(response) {
                        Task { await refreshWorkspace() }
                    }
                }
            } catch {
                try? store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
                noteMutationError = "A recovered remote note edit was not applied: \(error.localizedDescription)"
            }
        }
        try? store.database.dismissTerminalRemoteNoteEdits()
    }

    private func shouldUseOpenClawGateway(
        for conversation: WorkspaceConversationRecord
    ) async throws -> Bool {
        openClawGatewayConversationIDs.contains(conversation.id)
    }

    func canAgentEditOpenNote(_ conversation: WorkspaceConversationRecord?) -> Bool {
        guard let conversation else { return false }
        return conversation.localRuntimeKind != nil
    }

    private func acceptOpenClawGatewayMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard openClawGatewayConversationIDs.contains(conversation.id) else {
            throw OpenClawGatewayClientError.invalidEndpoint
        }
        return try await store.acceptOpenClawGatewayPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    private func acceptLocalAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard let runtimeKind = conversation.localRuntimeKind else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        if conversation.remoteWorkspaceID != nil, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Remote workspace file upload is not available yet. Add the file to the remote workspace first."
            )
        }
        if runtimeKind == .pi, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Pi RPC does not expose a file attachment contract yet."
            )
        }
        return try await store.acceptLocalACPPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            },
            onInteraction: { request in
                await self.requestLocalACPInteraction(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    private func finishAgentRunInteractions(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
    }

    func refreshLocalACPSession(
        conversation: WorkspaceConversationRecord
    ) async {
        guard let runtimeKind = conversation.localRuntimeKind else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            return
        }
        let request = localACPSessionRefreshLifecycle.beginRefresh(
            for: conversation.id
        )
        defer { localACPSessionRefreshLifecycle.finish(request) }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let configuration = try await dashboardStore
                .localACPSessionConfiguration(
                    conversationID: conversation.id,
                    launch: launch,
                    workspace: workspace
                )
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            localACPSessionMetadata[conversation.id] = LocalACPSessionMetadata(
                sessionKey: conversation.id,
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingLevels: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands
            )
            ensureConversationState(id: conversation.id).setError(nil)
        } catch {
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            ensureConversationState(id: conversation.id).setError(
                error.localizedDescription
            )
        }
    }

    func updateLocalACPSession(
        conversation: WorkspaceConversationRecord,
        model: String? = nil,
        thinking: String? = nil
    ) {
        guard let runtimeKind = conversation.localRuntimeKind,
              model != nil || thinking != nil,
              !localRunningConversationIDs.contains(conversation.id),
              updatingLocalACPSessionIDs.insert(conversation.id).inserted else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            updatingLocalACPSessionIDs.remove(conversation.id)
            return
        }
        localRunError = nil
        ensureConversationState(id: conversation.id).setError(nil)
        Task {
            defer { updatingLocalACPSessionIDs.remove(conversation.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let configuration = try await dashboardStore
                    .updateLocalACPSessionConfiguration(
                        conversationID: conversation.id,
                        model: model,
                        thinking: thinking,
                        launch: launch,
                        workspace: workspace
                    )
                localACPSessionMetadata[conversation.id] =
                    LocalACPSessionMetadata(
                        sessionKey: conversation.id,
                        model: configuration.model,
                        thinking: configuration.thinking,
                        modelOptions: configuration.modelOptions,
                        thinkingLevels: configuration.thinkingOptions,
                        slashCommands: configuration.slashCommands
                    )
            } catch {
                ensureConversationState(id: conversation.id).setError(
                    error.localizedDescription
                )
            }
        }
    }

    func createLocalACPSession(
        runtimeKind: AgentRuntimeKind
    ) async -> String? {
        guard localACPLaunchConfigurations[runtimeKind] != nil,
              localACPWorkspaceLaunchConfiguration != nil,
              isLocalACPAgentReady(runtimeKind) else {
            localRunError = ApplicationModelError.localACPRuntimeUnavailable.localizedDescription
            return nil
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let conversationID = try await dashboardStore.createLocalACPSession(
                runtimeKind: runtimeKind,
                title: "New \(runtimeKind.displayName) chat"
            )
            if runtimeKind == .openclaw,
               let agent = localCLIAgents.first(where: { $0.runtimeKind == .openclaw }),
               isOpenClawGatewayLinked(agentID: agent.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: agent.id,
                    sessionKey: Self.openClawSessionKey(conversationID: conversationID)
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            NSLog(
                "Could not create %@ local ACP chat: %@",
                runtimeKind.rawValue,
                String(describing: error)
            )
            localRunError = error is WorkspaceDatabaseError
                ? "Woven Matter could not save this local chat. Reopen the app and try again."
                : error.localizedDescription
            return nil
        }
    }

    func createRemoteACPSession(
        target: RemoteHarnessChatTarget
    ) async -> String? {
        guard remoteWorkspaces.isHarnessReady(
            target.harness.id,
            in: target.configuration
        ) else {
            localRunError = "This remote harness is not ready. Refresh it in Settings and try again."
            return nil
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            var unlinkedOpenClawAgentID: UUID?
            let conversationID = try await dashboardStore.createRemoteACPSession(
                runtimeKind: target.harness.id,
                remoteWorkspaceID: target.configuration.id,
                remoteWorkspaceName: target.configuration.name,
                title: "New \(target.harness.displayName) chat"
            )
            if target.harness.id == .openclaw {
                let agentID = try await dashboardStore.ensureRemoteHarnessAgent(
                    runtimeKind: .openclaw,
                    remoteWorkspaceID: target.configuration.id,
                    remoteWorkspaceName: target.configuration.name
                )
                if isOpenClawGatewayLinked(agentID: agentID) {
                    try await dashboardStore.attachOpenClawGatewaySession(
                        conversationID: conversationID,
                        agentID: agentID,
                        sessionKey: Self.openClawSessionKey(
                            conversationID: conversationID
                        )
                    )
                    openClawGatewayConversationIDs.insert(conversationID)
                } else {
                    unlinkedOpenClawAgentID = agentID
                }
            }
            localRunError = nil
            await refreshWorkspace()
            pendingOpenClawGatewayAgentID = unlinkedOpenClawAgentID
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            return nil
        }
    }

    private func directACPLaunchContext(
        conversation: WorkspaceConversationRecord,
        runtimeKind: AgentRuntimeKind,
        isBuzzWorkspaceSession: Bool
    ) throws -> RemoteHarnessLaunchContext? {
        if isBuzzWorkspaceSession { return nil }
        if let remoteWorkspaceID = conversation.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(
                id: remoteWorkspaceID
            ), remoteWorkspaces.isHarnessReady(runtimeKind, in: configuration) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            let processDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
                ?? FileManager.default.homeDirectoryForCurrentUser
            return try RemoteHarnessLaunchResolver.resolve(
                configuration: configuration,
                runtimeKind: runtimeKind,
                processWorkingDirectory: processDirectory
            )
        }
        guard let launch = localACPLaunchConfigurations[runtimeKind],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        return RemoteHarnessLaunchContext(
            launch: launch,
            workspace: workspace
        )
    }

    func createBuzzWorkspaceLocalACPSession(
        enrollment: BuzzWorkspaceAgentEnrollment
    ) async -> String? {
        guard launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id) else {
            localRunError = "The selected Buzz agent is not available from its linked workspace."
            return nil
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let conversationID = try await dashboardStore
                .createBuzzWorkspaceLocalACPSession(
                    enrollmentID: enrollment.id,
                    title: "New \(enrollment.displayNameSnapshot) chat"
                )
            buzzBoundLocalACPConversationIDs.insert(conversationID)
            if isOpenClawGatewayLinked(agentID: enrollment.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: enrollment.id,
                    sessionKey: Self.openClawSessionKey(conversationID: conversationID)
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            await refreshBuzzWorkspaces()
            return nil
        }
    }

    func clearNewChatError() {
        newChatError = nil
    }

    func installLocalACPRuntimeComponent(_ runtimeKind: AgentRuntimeKind) {
        guard !installingLocalACPRuntimeKinds.contains(runtimeKind),
              let definition = LocalACPRuntimeCatalog.definition(
                for: runtimeKind
              ),
              let availability = localACPRuntimeAvailability.first(
                where: { $0.runtimeKind == runtimeKind }
              )
        else { return }
        let component: LocalACPRuntimeInstallComponent
        if availability.needsCLIInstallation {
            component = .cli
        } else if availability.needsAdapterInstallation {
            component = .adapter
        } else {
            return
        }
        if case .cli = component {
            installingLocalACPRuntimeKinds.insert(runtimeKind)
            localRunError = nil
            Task {
                defer { installingLocalACPRuntimeKinds.remove(runtimeKind) }
                do {
                    let preview = try await localACPRuntimeInstaller
                        .prepareCLIInstall(definition)
                    preparedLocalACPRuntimeInstall =
                        PreparedLocalACPRuntimeInstall(
                            definition: definition,
                            preview: preview
                        )
                } catch {
                    localRunError = error.localizedDescription
                }
            }
            return
        }
        performLocalACPRuntimeInstall(definition, component: component)
    }

    func confirmPreparedLocalACPRuntimeInstall() {
        guard let preparedLocalACPRuntimeInstall else { return }
        self.preparedLocalACPRuntimeInstall = nil
        let runtimeKind = preparedLocalACPRuntimeInstall.definition.runtimeKind
        guard !installingLocalACPRuntimeKinds.contains(runtimeKind) else {
            return
        }
        installingLocalACPRuntimeKinds.insert(runtimeKind)
        localRunError = nil
        Task {
            defer { installingLocalACPRuntimeKinds.remove(runtimeKind) }
            do {
                _ = try await localACPRuntimeInstaller.install(
                    preparedLocalACPRuntimeInstall.definition,
                    component: .cli,
                    expectedSourceSHA256:
                        preparedLocalACPRuntimeInstall.preview.sha256,
                    expectedPackageSpec:
                        preparedLocalACPRuntimeInstall.preview.packageSpec
                )
                await refreshLocalACPRuntimes()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func cancelPreparedLocalACPRuntimeInstall() {
        preparedLocalACPRuntimeInstall = nil
    }

    private func performLocalACPRuntimeInstall(
        _ definition: LocalACPRuntimeDefinition,
        component: LocalACPRuntimeInstallComponent
    ) {
        let runtimeKind = definition.runtimeKind
        installingLocalACPRuntimeKinds.insert(runtimeKind)
        localRunError = nil
        Task {
            defer { installingLocalACPRuntimeKinds.remove(runtimeKind) }
            do {
                _ = try await localACPRuntimeInstaller.install(
                    definition,
                    component: component
                )
                await refreshLocalACPRuntimes()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func refreshLocalACPRuntimesNow() {
        Task { await refreshLocalACPRuntimes() }
    }

    func setTitleGenerationEnabled(_ enabled: Bool) {
        titleGenerationSettings.isEnabled = enabled
        applicationDefaults.set(
            enabled,
            forKey: Self.titleGenerationEnabledDefaultsKey
        )
    }

    func setTitleGenerationModel(_ model: String) {
        titleGenerationSettings.model = model
        applicationDefaults.set(
            model,
            forKey: Self.titleGenerationModelDefaultsKey
        )
    }

    func setTitleGenerationThinking(_ thinking: String) {
        titleGenerationSettings.thinking = thinking
        applicationDefaults.set(
            thinking,
            forKey: Self.titleGenerationThinkingDefaultsKey
        )
    }

    func refreshTitleGenerationCapabilitiesNow() {
        Task { await refreshTitleGenerationCapabilities() }
    }

    func setUpLocalACPWorkspace(homeDirectory: URL) {
        Task {
            do {
                try await localACPWorkspaceStore.setUpWorkspace(
                    in: homeDirectory
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshLocalACPRuntimes()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPRepositories(_ repositoriesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureRepositories(
                    repositoriesURL
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPDatabases(_ databasesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureDatabases(databasesURL)
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshDatabases()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func resolveLocalACPPermission(id: UUID, optionID: String?) {
        guard let continuation = localACPPermissionContinuations.removeValue(forKey: id) else {
            return
        }
        pendingLocalACPPermissions.removeAll { $0.id == id }
        continuation.resume(returning: optionID)
    }

    func resolveLocalACPInteraction(
        id: UUID,
        response: LocalACPInteractionResponse
    ) {
        guard let continuation = localACPInteractionContinuations.removeValue(
            forKey: id
        ) else { return }
        pendingLocalACPInteractions.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelLocalACPPrompt(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
        Task {
            await dashboardStore?.cancelLocalACPPrompt(conversationID: conversationID)
        }
    }

    func shutdownLocalACPSessions() {
        let permissionIDs = pendingLocalACPPermissions.map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        let interactionIDs = pendingLocalACPInteractions.map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
        LocalACPClient.terminateAllProcesses()
        PiRPCClient.terminateAllProcesses()
        Task { await dashboardStore?.shutdownLocalACPSessions() }
    }

    private func requestLocalACPPermission(
        conversationID: String,
        request: LocalACPPermissionRequest
    ) async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPPermissionContinuations[id] = continuation
                pendingLocalACPPermissions.append(PendingLocalACPPermission(
                    id: id,
                    conversationID: conversationID,
                    title: request.title,
                    options: request.options
                ))
                if Task.isCancelled {
                    resolveLocalACPPermission(id: id, optionID: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPPermission(id: id, optionID: nil)
            }
        }
    }

    private func requestLocalACPInteraction(
        conversationID: String,
        request: LocalACPInteractionRequest
    ) async -> LocalACPInteractionResponse {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPInteractionContinuations[id] = continuation
                pendingLocalACPInteractions.append(PendingLocalACPInteraction(
                    id: id,
                    conversationID: conversationID,
                    request: request
                ))
                if Task.isCancelled {
                    resolveLocalACPInteraction(id: id, response: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPInteraction(id: id, response: .cancelled)
            }
        }
    }

    private func cancelLocalACPInteractions(conversationID: String) {
        let interactionIDs = pendingLocalACPInteractions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
    }

    private func refreshLocalACPRuntimes() async {
        localACPRuntimeRefreshGeneration &+= 1
        let generation = localACPRuntimeRefreshGeneration
        checkingLocalACPRuntimeKinds = Set(
            LocalACPRuntimeCatalog.definitions.compactMap {
                $0.readinessProbe == nil ? nil : $0.runtimeKind
            }
        )
        defer {
            if generation == localACPRuntimeRefreshGeneration {
                checkingLocalACPRuntimeKinds.removeAll()
            }
        }
        let resolver = localACPRuntimeResolver
        let definitions = LocalACPRuntimeCatalog.definitions
        let workingDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        let resolutions = await Task.detached(priority: .utility) {
            var resolutions: [LocalACPRuntimeResolution] = []
            for definition in definitions {
                let discovered = resolver.resolve(
                    runtimeKind: definition.runtimeKind
                )
                resolutions.append(await LocalACPRuntimeVerifier.verify(
                    definition: definition,
                    resolution: discovered,
                    workingDirectory: workingDirectory
                ))
            }
            return resolutions
        }.value
        guard !Task.isCancelled,
              generation == localACPRuntimeRefreshGeneration else {
            return
        }
        localACPRuntimeAvailability = resolutions.map(\.availability)
        localACPLaunchConfigurations = resolutions.reduce(into: [:]) {
            configurations, resolution in
            if let launchConfiguration = resolution.launchConfiguration {
                configurations[resolution.availability.runtimeKind] =
                    launchConfiguration
            }
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: resolutions.map { resolution in
                let status: AgentRuntimeStatus = switch resolution.availability.state {
                case .ready: .ready
                case .authenticationRequired: .needsAuthentication
                case .executableUnavailable: .failed
                case .cliMissing, .adapterMissing, .adapterOutdated: .offline
                }
                return (resolution.availability.runtimeKind, status)
            }
        )
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.reconcileLocalCLIAgentCatalog(statuses: statuses)
            localACPDatabaseReadyRuntimeKinds = Set(statuses.keys)
            localACPAgentReconciliationError = nil
            await refreshWorkspace()
        } catch {
            localACPDatabaseReadyRuntimeKinds.removeAll()
            localACPAgentReconciliationError =
                "The local workspace could not save Local CLI agents. Reopen Woven Matter and try again."
            NSLog(
                "Could not reconcile local CLI agents: %@",
                String(describing: error)
            )
        }
        await refreshTitleGenerationCapabilities()
    }

    private func refreshTitleGenerationCapabilities() async {
        guard !isRefreshingTitleGenerationCapabilities,
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            titleGenerationCapabilities = nil
            titleGenerationStatus = "Codex CLI and codex-acp must be ready"
            return
        }
        isRefreshingTitleGenerationCapabilities = true
        defer { isRefreshingTitleGenerationCapabilities = false }
        do {
            let capabilities = try await conversationTitleGenerator.discover(
                launch: launch,
                workspace: workspace
            )
            titleGenerationCapabilities = capabilities
            if !capabilities.models.contains(titleGenerationSettings.model),
               let model = capabilities.currentModel ?? capabilities.models.first {
                setTitleGenerationModel(model)
            }
            if !capabilities.thinkingLevels.contains(titleGenerationSettings.thinking),
               let thinking = capabilities.currentThinking
                    ?? capabilities.thinkingLevels.first {
                setTitleGenerationThinking(thinking)
            }
            titleGenerationStatus = "Ready through your local Codex account"
        } catch {
            titleGenerationCapabilities = nil
            titleGenerationStatus = error.localizedDescription
        }
    }

    private func scheduleConversationTitleGeneration(
        conversation: WorkspaceConversationRecord,
        firstPrompt: String
    ) {
        guard titleGenerationSettings.isEnabled,
              conversation.title.hasPrefix("New "),
              conversation.title.hasSuffix(" chat"),
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration,
              let dashboardStore,
              generatingConversationTitleIDs.insert(conversation.id).inserted else { return }
        let expectedTitle = conversation.title
        let selectedModel = titleGenerationSettings.model.isEmpty
            ? nil : titleGenerationSettings.model
        let selectedThinking = titleGenerationSettings.thinking.isEmpty
            ? nil : titleGenerationSettings.thinking
        Task {
            defer { generatingConversationTitleIDs.remove(conversation.id) }
            do {
                let generatedTitle = try await conversationTitleGenerator.generate(
                    firstPrompt: firstPrompt,
                    model: selectedModel,
                    thinking: selectedThinking,
                    launch: launch,
                    workspace: workspace
                )
                if try await dashboardStore.updateConversationTitleIfCurrent(
                    id: conversation.id,
                    expectedTitle: expectedTitle,
                    title: generatedTitle
                ) {
                    await refreshWorkspace()
                }
            } catch {
                NSLog(
                    "Could not generate title for conversation %@: %@",
                    conversation.id,
                    String(describing: error)
                )
            }
        }
    }

    private func refreshLocalACPWorkspace() async {
        let resolution = await localACPWorkspaceStore.resolve()
        localACPWorkspaceAvailability = resolution.availability
        localACPWorkspaceLaunchConfiguration = resolution.launchConfiguration
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

            databasesSnapshot = DashboardDatabasesSnapshot(sources: sources)
        } while databaseRefreshRequestedWhileRunning
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
        guard let url = database.localURL else {
            databaseError = "Remote database preferences are managed by their agent."
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try AgentDatabaseCatalog.setPreference(preference, for: url)
            }.value
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


    var buzzWorkspaceLinks: [BuzzWorkspaceLink] {
        buzzWorkspaceSnapshot.links
    }

    var buzzWorkspaceAgentEnrollments: [BuzzWorkspaceAgentEnrollment] {
        buzzWorkspaceSnapshot.enrollments
    }

    func isBuzzWorkspaceAgentLaunchable(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) -> Bool {
        launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id)
    }

    func setBuzzDiscoveryEnabled(_ enabled: Bool) {
        applicationDefaults.set(
            enabled,
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        )
        Task {
            if enabled {
                await refreshBuzzWorkspaces()
            } else {
                buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                    links: [],
                    enrollments: []
                )
                buzzWorkspaceCandidates.removeAll()
                launchableBuzzWorkspaceEnrollmentIDs.removeAll()
                buzzWorkspaceAgents = []
            }
            await refreshWorkspace()
        }
    }

    @discardableResult
    func addLocalBuzzWorkspace(
        displayName: String,
        workspacePath rawWorkspacePath: String,
        agentStorePath rawAgentStorePath: String
    ) async -> Bool {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            buzzWorkspaceError = "Enter a workspace name."
            return false
        }
        let workspaceURL = Self.expandedLocalFileURL(rawWorkspacePath)
        let storeURL = Self.expandedLocalFileURL(rawAgentStorePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspaceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            buzzWorkspaceError = "The selected Buzz workspace folder is unavailable."
            return false
        }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            buzzWorkspaceError = "The selected Buzz agent catalog is unavailable."
            return false
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let link = BuzzWorkspaceLink(
                displayName: cleanName,
                localWorkspaceURL: workspaceURL,
                localAgentStoreURL: storeURL
            )
            try await dashboardStore.saveBuzzWorkspace(link)
            buzzWorkspaceError = nil
            await refreshBuzzWorkspaces()
            await refreshWorkspace()
            return true
        } catch {
            buzzWorkspaceError = error.localizedDescription
            return false
        }
    }

    func discoverBuzzWorkspaceAgents(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        buzzWorkspaceError = nil
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                buzzWorkspaceCandidates[link.id] = try await dashboardStore
                    .discoverBuzzWorkspaceAgents(linkID: link.id)
            } catch {
                buzzWorkspaceCandidates[link.id] = []
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func enrollBuzzWorkspaceAgent(_ candidate: BuzzWorkspaceAgentCandidate) {
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let enrollment = try await dashboardStore
                    .enrollBuzzWorkspaceAgent(candidate)
                mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id)
                defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func removeBuzzWorkspaceAgentEnrollment(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) {
        guard mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id).inserted else {
            return
        }
        Task {
            defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.removeBuzzWorkspaceAgentEnrollment(
                    id: enrollment.id
                )
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func deleteBuzzWorkspace(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.deleteBuzzWorkspace(id: link.id)
                buzzWorkspaceCandidates.removeValue(forKey: link.id)
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    private func refreshBuzzWorkspaces() async {
        guard applicationDefaults.bool(
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        ) else {
            buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                links: [],
                enrollments: []
            )
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            return
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            launchableBuzzWorkspaceEnrollmentIDs = try await dashboardStore
                .reconcileBuzzWorkspaceAgents()
            buzzWorkspaceSnapshot = try await dashboardStore.buzzWorkspaceSnapshot()
            buzzBoundLocalACPConversationIDs = try await dashboardStore
                .buzzBoundLocalACPConversationIDs()
            buzzWorkspaceError = nil
        } catch {
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            buzzWorkspaceError = error.localizedDescription
        }
    }

    func isOpenClawGatewayLinked(agentID: UUID) -> Bool {
        openClawGatewayLinks.contains { $0.agentID == agentID }
    }

    func isOpenClawGatewayConversation(_ conversationID: String) -> Bool {
        openClawGatewayConversationIDs.contains(conversationID)
    }

    func openClawGatewayLink(agentID: UUID) -> OpenClawGatewayLink? {
        openClawGatewayLinks.first { $0.agentID == agentID }
    }

    func renameOpenClawAgent(agentID: UUID, displayName: String) {
        guard let dashboardStore else { return }
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            openClawGatewayErrors[agentID] = "Enter a Woven Matter agent name."
            return
        }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer { openClawGatewayOperationAgentIDs.remove(agentID) }
            do {
                try await dashboardStore.renameOpenClawAgent(
                    agentID: agentID,
                    displayName: cleanName
                )
                await refreshWorkspace()
                openClawGatewayNotices[agentID] = "Woven Matter name updated."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func linkOpenClawGateway(agent: WorkspaceAgent) {
        guard agent.runtimeKind == .openclaw, let dashboardStore else {
            openClawGatewayErrors[agent.id] = OpenClawGatewayEndpointResolutionError
                .openClawRequired.localizedDescription
            return
        }
        openClawGatewayOperationAgentIDs.insert(agent.id)
        openClawGatewayOperationStatuses[agent.id] = .connecting
        openClawGatewayErrors[agent.id] = nil
        openClawGatewayNotices[agent.id] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agent.id)
                openClawGatewayOperationStatuses[agent.id] = nil
            }
            do {
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    status: .connecting
                )
                let linked = try await dashboardStore.linkOpenClawGateway(link)
                if linked.connectionStatus == .ready {
                    try await dashboardStore.syncOpenClawCron(agentID: agent.id)
                }
                await refreshOpenClawGateways()
                await loadOpenClawCronSnapshot()
                openClawGatewayNotices[agent.id] = "Gateway connected and healthy."
            } catch {
                openClawGatewayErrors[agent.id] = error.localizedDescription
                await refreshOpenClawGateways()
            }
        }
    }

    func confirmPendingOpenClawGatewayLink() {
        guard let agentID = pendingOpenClawGatewayAgentID else { return }
        pendingOpenClawGatewayAgentID = nil
        guard let agent = openClawAgent(agentID: agentID) else { return }
        linkOpenClawGateway(agent: agent)
    }

    func dismissPendingOpenClawGatewayLink() {
        pendingOpenClawGatewayAgentID = nil
    }

    func unlinkOpenClawGateway(agentID: UUID) {
        guard let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .unlinking
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                try await dashboardStore.unlinkOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway unlinked from this Mac."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func reconnectOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .reconnecting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                _ = try await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .reconnecting
                )
                await refreshOpenClawGateways()
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    existing: existing,
                    status: .reconnecting
                )
                _ = try await dashboardStore.linkOpenClawGateway(link)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway reconnected and healthy."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func restartOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .restarting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                if existing.location == .localAgentWorkspace || existing.location == .buzzLocal {
                    let prepared = try await preparedOpenClawGatewayLink(
                        for: agent,
                        existing: existing,
                        status: .reconnecting
                    )
                    _ = try await dashboardStore.linkOpenClawGateway(prepared)
                }
                _ = try await dashboardStore.restartOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway restarted, reconnected, and passed health checks."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func refreshOpenClawGatewayStatus(agentID: UUID) async {
        guard openClawGatewayLink(agentID: agentID) != nil,
              !openClawGatewayOperationAgentIDs.contains(agentID),
              let dashboardStore else { return }
        do {
            _ = try await dashboardStore.refreshOpenClawGatewayStatus(agentID: agentID)
            openClawGatewayErrors[agentID] = nil
        } catch {
            openClawGatewayErrors[agentID] = error.localizedDescription
        }
        await refreshOpenClawGateways()
    }

    func loadOpenClawHeartbeat(agentID: UUID) async {
        guard let dashboardStore else { return }
        do {
            openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                .openClawHeartbeatConfiguration(agentID: agentID)
            openClawHeartbeatMessages[agentID] = nil
            openClawHeartbeatErrorAgentIDs.remove(agentID)
        } catch {
            openClawHeartbeatMessages[agentID] = error.localizedDescription
            openClawHeartbeatErrorAgentIDs.insert(agentID)
        }
    }

    func saveOpenClawHeartbeat(
        agentID: UUID,
        configuration: OpenClawHeartbeatConfiguration
    ) {
        guard let dashboardStore else { return }
        openClawHeartbeatSavingAgentIDs.insert(agentID)
        openClawHeartbeatMessages[agentID] = nil
        Task {
            defer { openClawHeartbeatSavingAgentIDs.remove(agentID) }
            do {
                openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                    .updateOpenClawHeartbeat(
                        agentID: agentID,
                        configuration: configuration
                    )
                openClawHeartbeatMessages[agentID] = "Heartbeat saved and confirmed by OpenClaw."
                openClawHeartbeatErrorAgentIDs.remove(agentID)
            } catch {
                openClawHeartbeatMessages[agentID] = error.localizedDescription
                openClawHeartbeatErrorAgentIDs.insert(agentID)
            }
        }
    }

    private func openClawAgent(agentID: UUID) -> WorkspaceAgent? {
        (localCLIAgents + remoteWorkspaceAgents + buzzWorkspaceAgents)
            .first { $0.id == agentID }
    }

    private func preparedOpenClawGatewayLink(
        for agent: WorkspaceAgent,
        existing: OpenClawGatewayLink? = nil,
        status: OpenClawGatewayConnectionStatus
    ) async throws -> OpenClawGatewayLink {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        let location: OpenClawGatewayLocation
        let endpoint: OpenClawGatewayEndpoint
        if agent.governingPlane == .remoteWorkspace {
            location = .remoteWorkspace
            guard let remoteWorkspaceID = agent.runtimeDeviceID,
                  let configuration = remoteWorkspaces.configuration(
                    id: remoteWorkspaceID
                  ) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            let connection = try await remoteWorkspaces.prepareOpenClawGateway(
                for: configuration
            )
            await dashboardStore.configureOpenClawGatewayTransport(
                agentID: agent.id,
                endpoint: connection.endpoint,
                requestHeaders: connection.requestHeaders
            )
            endpoint = connection.endpoint
        } else if let enrollment = buzzWorkspaceSnapshot.enrollments
            .first(where: { $0.id == agent.id }) {
            location = .buzzLocal
            endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                enrollmentID: enrollment.id,
                workspaceLinkID: enrollment.workspaceLinkID,
                remoteAgentID: enrollment.agentID
            )
        } else {
            location = .localAgentWorkspace
            guard let workspace = localACPWorkspaceLaunchConfiguration else {
                throw ApplicationModelError.localACPRuntimeUnavailable
            }
            endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                agentID: agent.id,
                workingDirectory: workspace.rootURL
            )
        }
        return OpenClawGatewayLink(
            agentID: agent.id,
            location: location,
            endpoint: endpoint,
            status: status.rawValue,
            openClawVersion: existing?.openClawVersion,
            lastConnectedAt: existing?.lastConnectedAt,
            lastError: nil,
            linkedAt: existing?.linkedAt ?? Date(),
            updatedAt: Date()
        )
    }

    func cancelOpenClawGatewayPrompt(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        Task {
            guard let dashboardStore else { return }
            do {
                try await dashboardStore.cancelOpenClawGatewayPrompt(
                    conversationID: conversationID
                )
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                await refreshConversation(id: conversationID)
                ensureConversationState(id: conversationID).setError(
                    "Unable to stop OpenClaw Gateway run: \(error.localizedDescription)"
                )
            }
        }
    }

    func patchOpenClawGatewaySession(
        conversationID: String,
        model: String?,
        thinkingLevel: String?
    ) {
        guard let dashboardStore else { return }
        Task {
            do {
                openClawGatewaySessionPreferences[conversationID] = try await dashboardStore
                    .patchOpenClawGatewaySession(
                        conversationID: conversationID,
                        preferences: OpenClawSessionPreferences(
                            model: model,
                            thinkingLevel: thinkingLevel
                        )
                    )
                openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                    .openClawGatewaySessionMetadata(conversationID: conversationID)
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                ensureConversationState(id: conversationID).setError(
                    error.localizedDescription
                )
            }
        }
    }

    func refreshOpenClawGatewaySession(conversationID: String) async {
        guard let dashboardStore else { return }
        do {
            openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                .openClawGatewaySessionMetadata(conversationID: conversationID)
            ensureConversationState(id: conversationID).setError(nil)
        } catch {
            ensureConversationState(id: conversationID).setError(
                error.localizedDescription
            )
        }
    }

    private func refreshOpenClawGateways() async {
        do {
            guard let dashboardStore else { return }
            openClawGatewayLinks = try await dashboardStore.openClawGatewayLinks()
            openClawGatewayConversationIDs = try await dashboardStore
                .openClawGatewayConversationIDs()
        } catch {
            for link in openClawGatewayLinks {
                openClawGatewayErrors[link.agentID] = error.localizedDescription
            }
        }
    }

    private func restoreOpenClawGatewayLinks() async {
        guard let dashboardStore else { return }
        for persisted in openClawGatewayLinks {
            do {
                var link = persisted
                switch persisted.location {
                case .buzzLocal:
                    guard let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
                        $0.id == persisted.agentID
                    }) else { throw BuzzWorkspaceDatabaseError.enrollmentNotFound }
                    link.endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                        enrollmentID: enrollment.id,
                        workspaceLinkID: enrollment.workspaceLinkID,
                        remoteAgentID: enrollment.agentID
                    )
                case .localAgentWorkspace:
                    guard let workspace = localACPWorkspaceLaunchConfiguration else {
                        throw ApplicationModelError.localACPRuntimeUnavailable
                    }
                    link.endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                        agentID: persisted.agentID,
                        workingDirectory: workspace.rootURL
                    )
                case .remoteWorkspace:
                    // Remote workspace tokens are intentionally not read during
                    // app startup. The user can reconnect this gateway from its
                    // workspace controls when they want Keychain access.
                    continue
                }
                _ = try await dashboardStore.linkOpenClawGateway(link)
            } catch {
                openClawGatewayErrors[persisted.agentID] = error.localizedDescription
            }
        }
        await refreshOpenClawGateways()
    }

    func refreshOpenClawCron() async {
        guard !isRefreshingOpenClawCron, let dashboardStore else { return }
        isRefreshingOpenClawCron = true
        defer { isRefreshingOpenClawCron = false }
        var failures: [String] = []
        for link in openClawGatewayLinks where link.connectionStatus == .ready {
            do {
                try await dashboardStore.syncOpenClawCron(agentID: link.agentID)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await loadOpenClawCronSnapshot()
        openClawCronError = failures.first
    }

    func emptyOpenClawCronTrash() {
        guard let dashboardStore else { return }
        Task {
            do {
                try await dashboardStore.emptyOpenClawCronTrash()
                await loadOpenClawCronSnapshot()
            } catch {
                openClawCronError = error.localizedDescription
            }
        }
    }

    func createOpenClawContextConversation(
        agentID: UUID,
        context: String? = nil
    ) async -> String? {
        let conversationID: String?
        if let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
            $0.id == agentID
        }) {
            conversationID = await createBuzzWorkspaceLocalACPSession(
                enrollment: enrollment
            )
        } else if localCLIAgents.contains(where: {
            $0.id == agentID && $0.runtimeKind == .openclaw
        }) {
            conversationID = await createLocalACPSession(runtimeKind: .openclaw)
        } else {
            localRunError = "The selected OpenClaw is no longer available."
            return nil
        }
        guard let conversationID else { return nil }
        if let context,
           let conversation = workspaceOverview?.conversations.first(where: {
               $0.id == conversationID
           }) {
            _ = await sendAgentMessage(
                conversation: conversation,
                content: context
            )
        }
        return conversationID
    }

    private func loadOpenClawCronSnapshot() async {
        guard let dashboardStore else { return }
        do {
            openClawCronJobs = try await dashboardStore.openClawCronJobs()
            openClawCronRuns = try await dashboardStore.openClawCronRuns()
        } catch {
            openClawCronError = error.localizedDescription
        }
    }

    private static func openClawSessionKey(conversationID: String) -> String {
        "agent:main:wovenmatter:\(conversationID)"
    }

    private static func expandedLocalFileURL(_ rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(trimmed.dropFirst(2)))
                .path
        } else {
            expanded = trimmed
        }
        return URL(filePath: expanded).standardizedFileURL
    }

    private func apply(_ snapshot: DashboardStoreSnapshot) {
        if loggedDashboardRecordCounts != snapshot.recordCounts {
            let counts = snapshot.recordCounts
            NSLog(
                "Dashboard database counts profiles=%d folders=%d notes=%d agents=%d conversations=%d messages=%d runs=%d calendar_items=%d revision=%lld",
                counts.profiles,
                counts.folders,
                counts.notes,
                counts.agents,
                counts.conversations,
                counts.messages,
                counts.runs,
                counts.calendarItems,
                snapshot.workspace.revision
            )
            loggedDashboardRecordCounts = counts
        }
        let nextLocalCLIAgents = snapshot.agents.filter {
            $0.governingPlane == .wovenmatterMacOS
                && !($0.platformCodename?.hasPrefix("buzz-workspace:") ?? false)
        }
        let buzzDiscoveryEnabled = applicationDefaults.bool(
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        )
        let nextBuzzWorkspaceAgents = snapshot.agents.filter {
            buzzDiscoveryEnabled
                && $0.governingPlane == .wovenmatterMacOS
                && ($0.platformCodename?.hasPrefix("buzz-workspace:") ?? false)
        }
        let nextRemoteWorkspaceAgents = snapshot.agents.filter {
            $0.governingPlane == .remoteWorkspace
        }
        if localCLIAgents != nextLocalCLIAgents {
            localCLIAgents = nextLocalCLIAgents
        }
        if buzzWorkspaceAgents != nextBuzzWorkspaceAgents {
            buzzWorkspaceAgents = nextBuzzWorkspaceAgents
        }
        if remoteWorkspaceAgents != nextRemoteWorkspaceAgents {
            remoteWorkspaceAgents = nextRemoteWorkspaceAgents
        }
        if calendarItems != snapshot.calendarItems {
            calendarItems = snapshot.calendarItems
        }
        let nextOverview = DashboardWorkspaceOverview(snapshot.workspace)
        if workspaceOverview?.folders != nextOverview.folders
            || workspaceOverview?.conversations != nextOverview.conversations
            || workspaceOverview?.notes != nextOverview.notes {
            workspaceListRevision &+= 1
        }
        if workspaceOverview != nextOverview { workspaceOverview = nextOverview }
        let retainedConversationIDs = Set(snapshot.workspace.conversations.map(\.id))
        let removedConversationIDs = conversationStatesByID.keys.filter {
            !retainedConversationIDs.contains($0)
        }
        for conversationID in removedConversationIDs {
            conversationStatesByID.removeValue(forKey: conversationID)
        }
        if workspaceRevision != snapshot.revision {
            workspaceRevision = snapshot.revision
        }
    }

}

enum ApplicationModelError: LocalizedError {
    case applicationSupportUnavailable
    case dashboardStoreUnavailable
    case localACPRuntimeUnavailable
    case remoteHarnessUnavailable
    case localSessionConfigurationInProgress
    case steeringUnavailable
    case activeTurnLimitReached
    case noteContextUnavailable
    case noteDraftSaveFailed

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The dashboard database location is unavailable."
        case .dashboardStoreUnavailable:
            "The dashboard database is still starting."
        case .localACPRuntimeUnavailable:
            "This local ACP runtime is unavailable. Open Settings to install or update its CLI or adapter, then try again."
        case .remoteHarnessUnavailable:
            "This remote harness is unavailable. Start and refresh its workspace in Settings, then try again."
        case .localSessionConfigurationInProgress:
            "Wait for this direct chat to finish loading its model and thinking settings."
        case .steeringUnavailable:
            "This agent is still working in this chat. Try again when the current turn finishes."
        case .activeTurnLimitReached:
            "Woven Matter is already handling a large number of active turns. Let one finish, then try again."
        case .noteContextUnavailable:
            "The open note could not be attached to this run. Wait for it to finish saving, then try again."
        case .noteDraftSaveFailed:
            "The latest note draft could not be saved on this Mac. Your draft is preserved; retry after saving succeeds."
        }
    }
}

private struct UsageProviderSignInCommand: Sendable {
    let executable: URL
    let arguments: [String]
}

private enum UsageProviderSignInError: LocalizedError {
    case failed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .failed(let provider, let status):
            "\(provider) sign-in did not complete (exit status \(status))."
        }
    }
}
