import Foundation
import WovenMatterCompanion
#if canImport(Darwin)
import Darwin
#endif

public struct MobileNoteConflict: Codable, Equatable, Sendable {
  public var base: CompanionNote?
  public var local: CompanionNote
  public var remote: CompanionNote?
  public var reason: String
}
public struct MobileOutboxEntry: Codable, Equatable, Sendable {
  public var mutation: CompanionMutation
  public var submitted: Bool = false
}
public struct MobileCommandRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { command.commandID }
  public var command: CompanionCommand
  public var receipt: CompanionCommandReceipt?
}
public struct MobileStoreState: Codable, Equatable, Sendable {
  public var formatVersion = 1
  public var deviceID = UUID().uuidString.lowercased()
  public var workspaceID: String?
  public var cursor: Int64 = 0
  public var folders: [String: CompanionFolder] = [:]
  public var notes: [String: CompanionNote] = [:]
  public var bases: [String: CompanionNote] = [:]
  public var conflicts: [String: MobileNoteConflict] = [:]
  public var outbox: [MobileOutboxEntry] = []
  public var conversations: [String: CompanionConversation] = [:]
  public var transcripts: [String: CompanionTranscript] = [:]
  public var transcriptRecency: [String] = []
  public var commands: [MobileCommandRecord] = []
  public var launches: [MobileLaunchRecord] = []
  public var chatDrafts: [String: MobileChatDraft] = [:]
  public var localRevisionParents: [String: [String: Int64]] = [:]
  public var deletedNotes: Set<String> = []
  public var uncachedNoteIDs: Set<String> = []
  /// Optional for backward decoding of existing format-1 libraries.
  public var executionConversationIDs: Set<String>?
  public var centralDeletedConversationIDs: Set<String>?
  public var centralConversationIDs: Set<String>?
  public var pendingNoteDeletions: [String: CompanionNote]?
  public var pendingFolderDeletions: [String: CompanionFolder]?
  public init() {}
  public func isDirty(_ id: String) -> Bool { outbox.contains { $0.mutation.resourceID == id } || conflicts[id] != nil }
}

public actor MobileStore {
  public struct Budget: Sendable {
    public var transcriptCount: Int
    public var transcriptBytes: Int
    public var noteBytes: Int
    public init(transcriptCount: Int = 20, transcriptBytes: Int = 16 * 1_024 * 1_024, noteBytes: Int = 64 * 1_024 * 1_024) {
      self.transcriptCount = transcriptCount; self.transcriptBytes = transcriptBytes; self.noteBytes = noteBytes
    }
  }
  public enum Failure: Error, LocalizedError {
    case incompatibleStore, wrongWorkspace, missingNote, conflictingNote, noteTooLarge, storageBudget, malformedAcknowledgement
    public var errorDescription: String? {
      switch self {
      case .incompatibleStore: "This local library needs a newer version of Woven Matter."
      case .wrongWorkspace: "This iPhone belongs to a different workspace. Its local writing has been kept."
      case .missingNote: "The note is no longer available."
      case .conflictingNote: "Resolve this note’s saved conflict before sending it to an agent."
      case .noteTooLarge: "This note exceeds the 4 MB document limit. Your previous saved version is safe."
      case .storageBudget: "The local note library is full. Your saved writing is safe. Free storage before adding more notes."
      case .malformedAcknowledgement: "The Mac returned an incomplete acknowledgement. The pending change has been kept."
      }
    }
  }
  public nonisolated let journal: WorkspaceJournal
  public nonisolated let artifacts: SavedArtifactStore
  private let file: URL
  private let budget: Budget
  private var state: MobileStoreState
  private var protectedNoteID: String?
  private var writeCount = 0
  private var lastWriteBytes = 0
  public init(file: URL, budget: Budget = .init()) throws {
    self.file = file; self.budget = budget
    journal = try WorkspaceJournal(file: file.appendingPathExtension("execution"))
    artifacts = try SavedArtifactStore(directory: file.appendingPathExtension("artifacts"))
    if FileManager.default.fileExists(atPath: file.path) {
      state = try MobileStorePersistence.load(from: file)
      guard state.formatVersion == 1 else { throw Failure.incompatibleStore }
    } else {
      state = MobileStoreState()
      _ = try MobileStorePersistence.persist(state, at: file)
    }
  }
  public func snapshot() -> MobileStoreState { state }
  public func protectOpenNote(_ id: String?) { protectedNoteID = id }
  public func verifyWorkspace(_ id: String) throws {
    guard state.workspaceID == nil || state.workspaceID == id else { throw Failure.wrongWorkspace }
  }
  public func cacheNote(_ note: CompanionNote) throws {
    try transaction { next in
      Self.remoteNote(note, state: &next)
      try enforceNoteBudget(&next, protecting: note.id)
    }
  }

  public func notesToCache() -> [String] {
    var remaining = max(0, budget.noteBytes - state.notes.values.filter { state.isDirty($0.id) }.reduce(0) { $0 + $1.content.utf8.count * 4 })
    var result: [String] = state.conflicts.values.compactMap { conflict in
      guard let remote = conflict.remote, !remote.contentIncluded else { return nil }
      return remote.id
    }
    for note in state.notes.values.sorted(by: { $0.updatedAt > $1.updatedAt }) where !state.isDirty(note.id) && (note.kind == nil || note.kind == .note) {
      let bytes = max(note.contentByteCount, note.content.utf8.count) * 2
      guard bytes <= remaining else { continue }
      remaining -= bytes
      if state.uncachedNoteIDs.contains(note.id) { result.append(note.id) }
    }
    return result
  }
  @discardableResult public func createFolder(name: String, id: String = UUID().uuidString.lowercased()) throws -> CompanionFolder {
    if let existing = state.folders[id] {
      guard existing.name == name else { throw Failure.conflictingNote }; return existing
    }
    guard state.pendingFolderDeletions?[id] == nil else { throw Failure.conflictingNote }
    let folder = CompanionFolder(id: id, name: name, revision: 0, updatedAt: Self.now)
    try transaction { next in
      next.folders[folder.id] = folder
      next.outbox.append(.init(mutation: .init(deviceID: next.deviceID, kind: .createFolder, resourceID: folder.id, title: name)))
    }
    return folder
  }
  @discardableResult public func createNote(folderID: String?, title: String, content: String, id: String = UUID().uuidString.lowercased()) throws -> CompanionNote {
    try Task.checkCancellation()
    guard state.notes[id] == nil, !state.deletedNotes.contains(id) else { throw Failure.conflictingNote }
    guard content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw Failure.noteTooLarge }
    let note = CompanionNote(id: id, folderID: folderID, title: title, content: content, revision: 0, updatedAt: Self.now)
    try transaction { next in
      next.notes[note.id] = note
      next.outbox.append(.init(mutation: Self.mutation(for: note, kind: .createNote, deviceID: next.deviceID)))
      try enforceNoteBudget(&next, protecting: note.id)
    }
    return note
  }
  public func renameFolder(id: String, name: String) throws {
    try transaction { next in
      guard var folder = next.folders[id] else { throw Failure.missingNote }
      guard folder.name != name else { return }
      guard !next.outbox.contains(where: { $0.mutation.resourceID == id && $0.submitted }) else { throw Failure.conflictingNote }
      folder.name = name; folder.updatedAt = Self.now; next.folders[id] = folder
      if let index = next.outbox.firstIndex(where: { $0.mutation.resourceID == id }) { next.outbox[index].mutation.title = name }
      else { next.outbox.append(.init(mutation: .init(deviceID: next.deviceID, kind: .renameFolder, resourceID: id, expectedRevision: folder.revision, title: name))) }
    }
  }
  /// Removing a nonempty folder requires an explicit move policy in the caller.
  public func deleteFolder(id: String) throws {
    if state.pendingFolderDeletions?[id] != nil { return }
    try transaction { next in
      guard let folder = next.folders[id] else { return }
      guard !next.notes.values.contains(where: { $0.folderID == id }),
        !next.outbox.contains(where: { $0.mutation.folderID == id || ($0.mutation.resourceID == id && $0.submitted) }) else { throw Failure.conflictingNote }
      next.outbox.removeAll { $0.mutation.resourceID == id }
      next.folders.removeValue(forKey: id)
      if folder.revision > 0 {
        if next.pendingFolderDeletions == nil { next.pendingFolderDeletions = [:] }
        next.pendingFolderDeletions?[id] = folder
        next.outbox.append(.init(mutation: .init(deviceID: next.deviceID, kind: .deleteFolder, resourceID: id, expectedRevision: folder.revision)))
      }
    }
  }
  public func deleteWorkspaceNote(id: String, base: CompanionNote) throws {
    if state.pendingNoteDeletions?[id] != nil || (state.deletedNotes.contains(id) && state.notes[id] == nil) { return }
    try transaction { next in
      guard let note = next.notes[id] else { return }
      guard note.revision == base.revision, note.title == base.title, note.content == base.content,
        note.folderID == base.folderID, next.conflicts[id] == nil,
        !next.outbox.contains(where: { $0.mutation.resourceID == id && $0.submitted }) else { throw Failure.conflictingNote }
      next.outbox.removeAll { $0.mutation.resourceID == id }
      next.notes.removeValue(forKey: id); next.deletedNotes.insert(id)
      if note.revision > 0 {
        if next.pendingNoteDeletions == nil { next.pendingNoteDeletions = [:] }
        next.pendingNoteDeletions?[id] = note
        next.outbox.append(.init(mutation: .init(deviceID: next.deviceID, kind: .deleteNote, resourceID: id, expectedRevision: note.revision)))
      }
    }
  }
  /// Import writes from an execution workspace through the same conflict/outbox
  /// path as an editor. A deleted canonical ID is never silently recreated.
  public func importWorkspaceNote(_ note: CompanionNote, base: CompanionNote? = nil) throws {
    guard note.content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw Failure.noteTooLarge }
    if state.deletedNotes.contains(note.id) || (state.notes[note.id] == nil && base != nil) {
      try transaction { next in
        next.notes[note.id] = note
        next.conflicts[note.id] = .init(base: base, local: note, remote: nil,
          reason: "This note was deleted from the central library. The execution workspace's writing is preserved.")
        next.outbox.removeAll { $0.mutation.resourceID == note.id }
        try enforceNoteBudget(&next, protecting: note.id)
      }
    } else if let current = state.notes[note.id], let base,
      (current.title != base.title || current.content != base.content || current.folderID != base.folderID),
      (current.title != note.title || current.content != note.content || current.folderID != note.folderID) {
      try transaction { next in
        next.conflicts[note.id] = .init(base: base, local: note, remote: current,
          reason: "The note was edited on this device while its workspace was running. Both versions have been preserved.")
        next.notes[note.id] = note
        next.outbox.removeAll { $0.mutation.resourceID == note.id }
        try enforceNoteBudget(&next, protecting: note.id)
      }
    } else if state.notes[note.id] != nil {
      try editNote(id: note.id, title: note.title, content: note.content, folderID: note.folderID, base: base)
    } else {
      _ = try createNote(folderID: note.folderID, title: note.title, content: note.content, id: note.id)
    }
  }
  /// Agent tools compare the exact body they read, including unacknowledged
  /// edits whose central revision has not changed. The check and write are atomic.
  public func editNoteIfUnchanged(id: String, title: String, content: String, folderID: String?, expected: CompanionNote) throws {
    guard state.notes[id] == expected, state.conflicts[id] == nil, !state.deletedNotes.contains(id) else { throw Failure.conflictingNote }
    try Task.checkCancellation()
    try editNote(id: id, title: title, content: content, folderID: folderID, base: expected)
  }
  public func editNote(id: String, title: String, content: String, folderID: String?, base: CompanionNote? = nil) throws {
    guard content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw Failure.noteTooLarge }
    try transaction { next in
      guard var note = next.notes[id] else { throw Failure.missingNote }
      if next.uncachedNoteIDs.contains(id), base?.contentIncluded != true { throw Failure.missingNote }
      guard note.title != title || note.content != content || note.folderID != folderID else { return }
      if let base, base.revision != note.revision {
        var ancestor = note.revision
        var visited = Set<Int64>()
        while ancestor != base.revision, visited.insert(ancestor).inserted,
              let parent = next.localRevisionParents[id]?[String(ancestor)] { ancestor = parent }
        if ancestor != base.revision {
          var local = base; local.title = title; local.content = content; local.folderID = folderID
          next.conflicts[id] = .init(base: base, local: local, remote: note, reason: "The Mac changed this note while your edit was being saved. Both versions are preserved.")
          next.notes[id] = local
          next.outbox.removeAll { $0.mutation.resourceID == id }
          return
        }
      }
      note.title = title; note.content = content; note.folderID = folderID; note.updatedAt = Self.now
      note.contentIncluded = true; note.contentByteCount = content.utf8.count; next.uncachedNoteIDs.remove(id)
      next.notes[id] = note
      if var conflict = next.conflicts[id] { conflict.local = note; next.conflicts[id] = conflict }
      else if let index = next.outbox.firstIndex(where: { $0.mutation.resourceID == id && !$0.submitted }) {
        next.outbox[index].mutation.title = title; next.outbox[index].mutation.content = content
        next.outbox[index].mutation.folderID = folderID
      } else if !next.outbox.contains(where: { $0.mutation.resourceID == id }) {
        next.outbox.append(.init(mutation: Self.mutation(for: note, kind: .updateNote, deviceID: next.deviceID)))
      }
      try enforceNoteBudget(&next, protecting: id)
    }
  }
  /// Marking submitted is itself durable. A retry must resend exactly these bytes and ID.
  public func nextMutation() throws -> CompanionMutation? {
    guard let index = state.outbox.firstIndex(where: { entry in
      state.conflicts[entry.mutation.resourceID] == nil &&
      !(entry.mutation.folderID.map { parent in state.outbox.contains { $0.mutation.kind == .createFolder && $0.mutation.resourceID == parent } } ?? false)
    }) else { return nil }
    let result = state.outbox[index].mutation
    try transaction { $0.outbox[index].submitted = true }
    return result
  }
  public func acknowledge(_ result: CompanionMutationResult) throws {
    guard let entry = state.outbox.first(where: { $0.mutation.operationID == result.operationID }) else { return }
    let mutation = entry.mutation
    var result = result
    if result.status == .accepted, var note = result.note, !note.contentIncluded, let content = mutation.content {
      note.content = content; note.contentIncluded = true; note.contentByteCount = content.utf8.count; result.note = note
    }
    try transaction { next in
      switch result.status {
      case .accepted:
        if mutation.kind == .createFolder || mutation.kind == .renameFolder {
          guard let folder = result.folder else { throw Failure.malformedAcknowledgement }
          next.folders[folder.id] = folder
        } else if mutation.kind == .createNote || mutation.kind == .updateNote {
          guard let remote = result.note, let local = next.notes[mutation.resourceID] else { throw Failure.malformedAcknowledgement }
          next.localRevisionParents[remote.id, default: [:]][String(remote.revision)] = mutation.expectedRevision ?? 0
          next.bases[remote.id] = remote
          if local.content == mutation.content && local.title == mutation.title && local.folderID == mutation.folderID {
            next.notes[remote.id] = remote
          } else {
            var newer = local; newer.revision = remote.revision; next.notes[remote.id] = newer
            next.outbox.append(.init(mutation: Self.mutation(for: newer, kind: .updateNote, deviceID: next.deviceID)))
          }
        }
        if mutation.kind == .deleteNote { next.notes.removeValue(forKey: mutation.resourceID); next.pendingNoteDeletions?.removeValue(forKey: mutation.resourceID) }
        if mutation.kind == .deleteFolder { next.folders.removeValue(forKey: mutation.resourceID); next.pendingFolderDeletions?.removeValue(forKey: mutation.resourceID) }
        next.outbox.removeAll { $0.mutation.operationID == result.operationID }
      case .conflict, .notFound, .invalid:
        if mutation.kind == .deleteNote, let saved = next.pendingNoteDeletions?.removeValue(forKey: mutation.resourceID) {
          next.outbox.removeAll { $0.mutation.operationID == result.operationID }
          if result.status == .notFound { return }
          next.notes[saved.id] = saved
          next.conflicts[saved.id] = .init(base: next.bases[saved.id], local: saved, remote: result.note,
            reason: result.message ?? "The note changed before deletion. Its contents have been preserved.")
          return
        }
        if mutation.kind == .deleteFolder, let saved = next.pendingFolderDeletions?.removeValue(forKey: mutation.resourceID) {
          next.outbox.removeAll { $0.mutation.operationID == result.operationID }
          if result.status != .notFound { next.folders[saved.id] = result.folder ?? saved }
          return
        }
        if let local = next.notes[mutation.resourceID] {
          next.conflicts[local.id] = .init(base: next.bases[local.id], local: local, remote: result.note, reason: result.message ?? "The Mac version changed.")
        }
        // Folder failures remain visible in outbox; they do not permit dependent notes to run.
        if next.notes[mutation.resourceID] != nil { next.outbox.removeAll { $0.mutation.resourceID == mutation.resourceID } }
      }
    }
  }
  public func apply(_ snapshot: CompanionSnapshot) throws {
    try transaction { next in
      try Self.checkWorkspace(snapshot.workspaceID, state: &next)
      let remoteNotes = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
      for id in Array(next.notes.keys) where remoteNotes[id] == nil && next.bases[id] != nil { Self.remoteDeletion(id, state: &next) }
      for note in snapshot.notes { Self.remoteNote(note, state: &next) }
      let pendingFolders = next.folders.filter { id, _ in next.outbox.contains { $0.mutation.resourceID == id } }
      next.folders = Dictionary(uniqueKeysWithValues: snapshot.folders.filter { next.pendingFolderDeletions?[$0.id] == nil }.map { ($0.id, $0) }).merging(pendingFolders) { _, local in local }
      let incomingIDs = Set(snapshot.conversations.map(\.id))
      let missingIDs = (next.centralConversationIDs ?? []).subtracting(incomingIDs)
      next.centralDeletedConversationIDs = (next.centralDeletedConversationIDs ?? []).union(missingIDs).subtracting(incomingIDs)
      next.centralConversationIDs = incomingIDs
      let execution = next.conversations.filter { next.executionConversationIDs?.contains($0.key) == true && next.centralDeletedConversationIDs?.contains($0.key) != true }
      next.conversations = Dictionary(uniqueKeysWithValues: snapshot.conversations.map { ($0.id, $0) }).merging(execution) { _, local in local }
      next.cursor = snapshot.cursor
      try enforceNoteBudget(&next)
    }
  }
  public func apply(_ page: CompanionChangePage) throws {
    guard !page.resetRequired else { return }
    try transaction { next in
      try Self.checkWorkspace(page.workspaceID, state: &next)
      for change in page.changes where change.cursor > next.cursor {
        switch change.resourceKind {
        case .note:
          if change.operation == .delete { Self.remoteDeletion(change.resourceID, state: &next) }
          else if let note = change.note { Self.remoteNote(note, state: &next) }
        case .folder:
          if change.operation == .delete { next.folders.removeValue(forKey: change.resourceID) }
          else if let folder = change.folder, next.pendingFolderDeletions?[folder.id] == nil { next.folders[folder.id] = folder }
        case .conversation:
          if change.operation == .delete {
            next.conversations.removeValue(forKey: change.resourceID); next.transcripts.removeValue(forKey: change.resourceID)
            next.centralDeletedConversationIDs = (next.centralDeletedConversationIDs ?? []).union([change.resourceID])
          } else if let conversation = change.conversation {
            next.conversations[conversation.id] = conversation
            next.centralConversationIDs = (next.centralConversationIDs ?? []).union([conversation.id])
            next.centralDeletedConversationIDs?.remove(conversation.id)
          }
        case .transcript, .providers: break
        }
      }
      next.cursor = max(next.cursor, page.cursor)
      try enforceNoteBudget(&next)
    }
  }
  /// Rebuild the disposable UI projection after any interrupted replay. The
  /// journal cursor may commit before a cache write; restarting never loses data.
  public func restoreExecutionProjection() async throws {
    let history = await journal.snapshot()
    try transaction { next in
      for id in history.deletedConversationIDs {
        next.conversations.removeValue(forKey: id); next.transcripts.removeValue(forKey: id)
        next.executionConversationIDs?.remove(id)
      }
      for entry in history.pendingEntries where entry.kind == .restoredConversation { next.centralDeletedConversationIDs?.remove(entry.conversationID) }
      for conversation in history.conversations.values where next.centralDeletedConversationIDs?.contains(conversation.id) != true {
        next.conversations[conversation.id] = conversation
        next.executionConversationIDs = (next.executionConversationIDs ?? []).union([conversation.id])
      }
    }
    let recent = history.conversations.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }.prefix(budget.transcriptCount)
    for conversation in recent.reversed() where state.centralDeletedConversationIDs?.contains(conversation.id) != true {
      if let transcript = history.transcripts[conversation.id] { try cache(transcript) }
    }
  }
  /// Read-through projection for the central host's own execution API. The
  /// authoritative snapshot/change feed continues to own these conversations.
  public func cacheCentralConversations(_ conversations: [CompanionConversation]) throws {
    try transaction { next in
      for conversation in conversations { next.conversations[conversation.id] = conversation }
    }
  }
  /// Projection only: execution history remains durable in the separate journal.
  public func adoptExecution(conversation: CompanionConversation? = nil, transcript: CompanionTranscript? = nil) throws {
    try transaction { next in
      if let conversation, next.centralDeletedConversationIDs?.contains(conversation.id) != true {
        next.conversations[conversation.id] = conversation
        next.executionConversationIDs = (next.executionConversationIDs ?? []).union([conversation.id])
      }
    }
    if let transcript { try cache(transcript) }
  }
  public func cache(_ transcript: CompanionTranscript) throws {
    guard state.transcripts[transcript.conversationID] != transcript else { return }
    try transaction { next in
      var bounded = transcript
      // Individual transcripts are truncated from the oldest end before eviction.
      while try JSONEncoder().encode(bounded).count > budget.transcriptBytes && !bounded.messages.isEmpty { bounded.messages.removeFirst() }
      if try JSONEncoder().encode(bounded).count > budget.transcriptBytes { bounded.activities = [] }
      next.transcripts[transcript.conversationID] = bounded
      next.transcriptRecency.removeAll { $0 == transcript.conversationID }
      next.transcriptRecency.insert(transcript.conversationID, at: 0)
      while try next.transcriptRecency.count > budget.transcriptCount || JSONEncoder().encode(next.transcripts).count > budget.transcriptBytes {
        guard let removed = next.transcriptRecency.popLast() else { break }
        next.transcripts.removeValue(forKey: removed)
      }
    }
  }
  public func saveChatDraft(key: String, draft: MobileChatDraft) throws {
    try transaction { $0.chatDrafts[key] = draft }
  }
  public func rememberLaunchIfMissing(_ launch: MobileLaunchRecord) throws {
    guard !state.launches.contains(where: { $0.id == launch.id }) else { return }
    try transaction { next in
      next.launches.append(launch)
      while next.launches.count > 200, let removable = next.launches.firstIndex(where: { $0.accepted || $0.terminalFailure }) { next.launches.remove(at: removable) }
    }
  }
  /// Receipt recovery may finish after send preparation. Merge only its receipt;
  /// never replace the persisted command bytes with an earlier launch snapshot.
  @discardableResult public func rememberLaunchReceipt(_ receipt: CompanionCommandReceipt, launchID: String) throws -> MobileLaunchRecord? {
    try transaction { next in
      guard let index = next.launches.firstIndex(where: { $0.id == launchID }) else { return }
      if receipt.commandID == next.launches[index].create.commandID {
        if !Self.terminal(next.launches[index].createReceipt) { next.launches[index].createReceipt = receipt }
      } else if receipt.commandID == next.launches[index].initialSend.commandID {
        if !Self.terminal(next.launches[index].sendReceipt) { next.launches[index].sendReceipt = receipt }
      }
    }
    return state.launches.first { $0.id == launchID }
  }
  public func prepareLaunchSend(id: String, noteRevision: Int64?) throws -> MobileLaunchRecord? {
    try transaction { next in
      guard let index = next.launches.firstIndex(where: { $0.id == id }), !next.launches[index].sendPrepared else { return }
      next.launches[index].initialSend.noteRevision = noteRevision
      next.launches[index].sendPrepared = true
    }
    return state.launches.first { $0.id == id }
  }
  private static func terminal(_ receipt: CompanionCommandReceipt?) -> Bool { receipt?.status == .completed || receipt?.status == .rejected }
  public func rememberCommand(_ command: CompanionCommand) throws {
    guard !state.commands.contains(where: { $0.id == command.commandID }) else { return }
    try transaction { next in
      next.commands.append(.init(command: command))
      if next.commands.count > 200 { next.commands.removeAll { $0.receipt?.status == .completed || $0.receipt?.status == .rejected } }
    }
  }
  public func rememberReceipt(_ receipt: CompanionCommandReceipt) throws {
    try transaction { next in
      if let index = next.commands.firstIndex(where: { $0.id == receipt.commandID }) { next.commands[index].receipt = receipt }
    }
  }
  /// Keep a conflict as a new explicit copy; never resurrect a deleted canonical ID.
  @discardableResult public func preserveConflictAsCopy(id: String) throws -> CompanionNote {
    guard let conflict = state.conflicts[id] else { throw Failure.missingNote }
    let copy = CompanionNote(id: UUID().uuidString.lowercased(), folderID: state.folders[conflict.local.folderID ?? ""]?.id,
      title: conflict.local.title + " — recovery copy", content: conflict.local.content, revision: 0, updatedAt: Self.now)
    try transaction { next in
      next.notes[copy.id] = copy
      next.outbox.append(.init(mutation: Self.mutation(for: copy, kind: .createNote, deviceID: next.deviceID)))
      if let remote = conflict.remote { next.notes[id] = remote; next.bases[id] = remote; next.deletedNotes.remove(id) }
      else { next.notes.removeValue(forKey: id); next.bases.removeValue(forKey: id) }
      next.conflicts.removeValue(forKey: id)
    }
    return copy
  }
  public func canonicalNote(id: String) throws -> CompanionNote {
    guard let note = state.notes[id] else { throw Failure.missingNote }
    guard !state.isDirty(id), note.revision > 0 else { throw Failure.conflictingNote }
    return note
  }
  private static var now: String { ISO8601DateFormatter().string(from: Date()) }
  private static func mutation(for note: CompanionNote, kind: CompanionMutation.Kind, deviceID: String) -> CompanionMutation {
    .init(deviceID: deviceID, kind: kind, resourceID: note.id, expectedRevision: kind == .createNote ? nil : note.revision,
          folderID: note.folderID, title: note.title, content: note.content)
  }
  private static func checkWorkspace(_ id: String, state: inout MobileStoreState) throws {
    guard state.workspaceID == nil || state.workspaceID == id else { throw Failure.wrongWorkspace }
    state.workspaceID = id
  }
  private static func remoteNote(_ note: CompanionNote, state: inout MobileStoreState) {
    if state.deletedNotes.contains(note.id), state.bases[note.id]?.revision ?? 0 >= note.revision { return }
    if state.isDirty(note.id) {
      if var conflict = state.conflicts[note.id] {
        var remote = note
        if !remote.contentIncluded, let previous = conflict.remote, previous.revision == remote.revision, previous.contentIncluded {
          remote.content = previous.content; remote.contentIncluded = true
        }
        if remote.revision >= (conflict.remote?.revision ?? 0) { conflict.remote = remote }
        state.conflicts[note.id] = conflict
      }
      // A submitted mutation may be visible before its acknowledgement; do not
      // interpret the feed as an acknowledgement or advance the edit precondition.
      return
    }
    guard note.revision >= (state.bases[note.id]?.revision ?? 0) else { return }
    if state.bases[note.id]?.revision != note.revision { state.localRevisionParents.removeValue(forKey: note.id) }
    var note = note
    if !note.contentIncluded {
      if let previous = state.notes[note.id], previous.revision == note.revision, previous.contentIncluded, !state.uncachedNoteIDs.contains(note.id) {
        note.content = previous.content; note.contentIncluded = true
      } else { state.uncachedNoteIDs.insert(note.id) }
    }
    state.notes[note.id] = note; state.bases[note.id] = note; state.deletedNotes.remove(note.id)
    if note.contentIncluded { state.uncachedNoteIDs.remove(note.id) }
  }
  private static func remoteDeletion(_ id: String, state: inout MobileStoreState) {
    state.deletedNotes.insert(id)
    if state.isDirty(id), let local = state.notes[id] {
      state.conflicts[id] = .init(base: state.bases[id], local: local, remote: nil, reason: "This note was deleted on the Mac. Your iPhone writing is preserved.")
      state.outbox.removeAll { $0.mutation.resourceID == id }
    } else { state.notes.removeValue(forKey: id) }
  }
  private func enforceNoteBudget(_ next: inout MobileStoreState, protecting: String? = nil) throws {
    func bytes(_ state: MobileStoreState) -> Int {
      let documents = state.notes.values.reduce(0) { $0 + $1.content.utf8.count }
        + state.bases.values.reduce(0) { $0 + $1.content.utf8.count }
      let conflicts = state.conflicts.values.reduce(0) { $0 + $1.local.content.utf8.count + ($1.base?.content.utf8.count ?? 0) + ($1.remote?.content.utf8.count ?? 0) }
      let pendingDeletes = state.pendingNoteDeletions?.values.reduce(0) { $0 + $1.content.utf8.count } ?? 0
      return documents + conflicts + pendingDeletes + state.outbox.reduce(0) { $0 + ($1.mutation.content?.utf8.count ?? 0) }
    }
    var total = bytes(next)
    guard total > budget.noteBytes else { return }
    for note in next.notes.values.sorted(by: { $0.updatedAt < $1.updatedAt }) where note.id != protecting && note.id != protectedNoteID && !next.isDirty(note.id) {
      // Keep folder/title/ID/revision discoverable; fetch the exact document online.
      next.notes[note.id]?.content = ""; next.bases[note.id]?.content = ""
      next.notes[note.id]?.contentIncluded = false; next.bases[note.id]?.contentIncluded = false
      next.uncachedNoteIDs.insert(note.id)
      total = bytes(next)
      if total <= budget.noteBytes { return }
    }
    guard total <= budget.noteBytes else { throw Failure.storageBudget }
  }

  private func transaction(_ operation: (inout MobileStoreState) throws -> Void) throws {
    var next = state
    try operation(&next)
    guard next != state else { return }
    lastWriteBytes = try MobileStorePersistence.persist(next, at: file)
    writeCount += 1
    state = next
  }
  public func persistenceStatistics() -> (writes: Int, lastBytes: Int) { (writeCount, lastWriteBytes) }
}
