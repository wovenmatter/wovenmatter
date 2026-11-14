import Foundation

/// Additive federation capability: legacy library protocol v3 records remain unchanged.
public enum FederationProtocol {
  public static let version = 1
  public static let capability = "library.federation.v1"
  public static let maximumBatchEntries = 200
  public static let maximumBatchBytes = 8 * 1_024 * 1_024
  public static let maximumEntryBytes = 1_024 * 1_024
  public static let maximumArtifactChunkBytes = 1_024 * 1_024
}

public struct LibraryIdentity: Codable, Equatable, Sendable {
  public var libraryID: String
  public var hostDeviceID: String
  public var protocolVersion: Int
  public init(libraryID: String, hostDeviceID: String, protocolVersion: Int = FederationProtocol.version) {
    self.libraryID = libraryID; self.hostDeviceID = hostDeviceID; self.protocolVersion = protocolVersion
  }
}

public struct ExecutionWorkspace: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case mac, linux, ios }
  public var id: String
  public var libraryID: String
  /// Device authorized to manage registration and archive grants; not necessarily the execution host.
  public var ownerDeviceID: String
  public var executionDeviceID: String?
  public var kind: Kind
  public var name: String
  public var endpoint: URL?
  public var capabilities: [String]
  /// Legacy observer enrollment metadata. Never grants origin-publication authority.
  public var journalDeviceIDs: [String]
  public var revision: Int64
  public var deleted: Bool
  /// Development routes are temporary; a missing endpoint withdraws their presence.
  public var developmentInstance: String?
  /// Copied snapshot owners retain history, not a live connection.
  public var retainedHistory: Bool?
  /// A Mac's one-time access setup status (Keychain and macOS privacy permissions).
  public var macAccess: MacAccessStatus?
  /// The owner a Mac writes into its folders' execution bindings
  /// (`device:<id>`). A Mac's registry id is a separate random value,
  /// so devices group its folders through this. Display grouping only.
  public var folderOwnerID: String?
  public var isVisibleInConnections: Bool {
    !deleted && retainedHistory != true && (developmentInstance == nil || endpoint != nil)
  }
  public init(id: String, libraryID: String, ownerDeviceID: String, kind: Kind, name: String,
              endpoint: URL? = nil, capabilities: [String] = [], executionDeviceID: String? = nil, journalDeviceIDs: [String] = [], revision: Int64 = 0, deleted: Bool = false, developmentInstance: String? = nil, retainedHistory: Bool? = nil, macAccess: MacAccessStatus? = nil, folderOwnerID: String? = nil) {
    self.id = id; self.libraryID = libraryID; self.ownerDeviceID = ownerDeviceID; self.kind = kind; self.name = name
    self.executionDeviceID = executionDeviceID
    self.endpoint = endpoint; self.capabilities = capabilities; self.journalDeviceIDs = journalDeviceIDs
    self.revision = revision; self.deleted = deleted
    self.developmentInstance = developmentInstance; self.retainedHistory = retainedHistory
    self.macAccess = macAccess
    self.folderOwnerID = folderOwnerID
  }

  /// Folder bindings and registry rows name the same device with or without a
  /// `device:`/`remote:` prefix; this returns the lowercased bare UUID when there is one.
  public static func displayID(_ value: String) -> String {
    for prefix in ["device:", "remote:"] where value.hasPrefix(prefix) {
      if let id = UUID(uuidString: String(value.dropFirst(prefix.count))) { return id.uuidString.lowercased() }
    }
    return UUID(uuidString: value)?.uuidString.lowercased() ?? value
  }

  /// A valid `folderOwnerID`: `device:` followed by a UUID.
  public static func isValidFolderOwnerID(_ value: String) -> Bool {
    value.hasPrefix("device:") && UUID(uuidString: String(value.dropFirst("device:".count))) != nil
  }

  /// The display id of the registry workspace that owns `owner`, a folder
  /// binding or registry reference. A workspace whose own id matches wins; else
  /// the live workspace that names it as `folderOwnerID`. Nil when none does.
  public static func displayOwner(of owner: String, in registry: [ExecutionWorkspace]) -> String? {
    let id = displayID(owner)
    if registry.contains(where: { displayID($0.id) == id }) { return id }
    let claims = registry.filter { !$0.deleted && $0.folderOwnerID.map(displayID) == id }
    return (claims.first { $0.retainedHistory != true } ?? claims.first).map { displayID($0.id) }
  }
}
public struct LibraryWorkspaceRegistration: Codable, Equatable, Sendable {
  public var workspace: ExecutionWorkspace
  public var expectedRevision: Int64?
  public init(workspace: ExecutionWorkspace, expectedRevision: Int64? = nil) {
    self.workspace = workspace; self.expectedRevision = expectedRevision
  }
}

/// Immutable records emitted by one execution owner. Runtime checkpoints and
/// working files are intentionally excluded. Importing a receipt never executes it.
public struct RetainedExecution: Codable, Equatable, Sendable {
  public var source: String
  public var nativeSessionID: String
  public var runtimeKind: String
  public var runID: String
  public var status: String
  public init(source: String, nativeSessionID: String, runtimeKind: String, runID: String, status: String) {
    self.source = source; self.nativeSessionID = nativeSessionID; self.runtimeKind = runtimeKind; self.runID = runID; self.status = status
  }
}

public struct ExecutionJournalEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case conversation, transcript, receipt, deletedConversation, restoredConversation, nativeRecord }
  public var id: String { eventID }
  public var eventID: String
  public var workspaceID: String
  public var originSequence: Int64
  public var conversationID: String
  public var runID: String?
  public var kind: Kind
  public var conversation: LibraryConversation?
  public var transcript: LibraryTranscript?
  public var receipt: LibraryCommandReceipt?
  public var nativeRecord: NativeRecordPart?
  public var retainedExecution: RetainedExecution?
  public init(eventID: String = UUID().uuidString.lowercased(), workspaceID: String, originSequence: Int64,
              conversationID: String, runID: String? = nil, kind: Kind,
              conversation: LibraryConversation? = nil, transcript: LibraryTranscript? = nil, receipt: LibraryCommandReceipt? = nil, nativeRecord: NativeRecordPart? = nil, retainedExecution: RetainedExecution? = nil) {
    self.eventID = eventID; self.workspaceID = workspaceID; self.originSequence = originSequence
    self.conversationID = conversationID; self.runID = runID; self.kind = kind
    self.nativeRecord = nativeRecord; self.retainedExecution = retainedExecution
    self.conversation = conversation; self.transcript = transcript; self.receipt = receipt
  }
}
public struct ExecutionJournalBatch: Codable, Equatable, Sendable {
  public var libraryID: String
  public var entries: [ExecutionJournalEntry]
  public init(libraryID: String, entries: [ExecutionJournalEntry]) { self.libraryID = libraryID; self.entries = entries }
}
public struct ExecutionJournalBatchResult: Codable, Equatable, Sendable {
  public var libraryID: String
  public var acceptedEventIDs: [String]
  public var cursor: Int64
  public init(libraryID: String, acceptedEventIDs: [String], cursor: Int64) {
    self.libraryID = libraryID; self.acceptedEventIDs = acceptedEventIDs; self.cursor = cursor
  }
}
/// A journal record a page covers without its contents: a newer build wrote
/// it and the serving member, or the reader, cannot decode it. A workspace's
/// sequence has no gaps, so the reader moves past exactly this position.
public struct ExecutionJournalSkip: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var originSequence: Int64
  public init(workspaceID: String, originSequence: Int64) { self.workspaceID = workspaceID; self.originSequence = originSequence }
}
public struct ExecutionJournalPage: Codable, Equatable, Sendable {
  public var libraryID: String
  /// The serving member's library cursor; unrelated to any workspace's originSequence.
  public var cursor: Int64
  public var entries: [ExecutionJournalEntry]
  public var hasMore: Bool
  /// Records the cursor covers that are not in `entries`. Absent unless one was skipped.
  public var skipped: [ExecutionJournalSkip]?
  public init(libraryID: String, cursor: Int64, entries: [ExecutionJournalEntry] = [], hasMore: Bool = false,
              skipped: [ExecutionJournalSkip]? = nil) {
    self.libraryID = libraryID; self.cursor = cursor; self.entries = entries; self.hasMore = hasMore
    self.skipped = skipped
  }
  /// A page read from another device keeps the entries this build can decode.
  /// An entry it cannot decode becomes a skip, which needs the entry's
  /// workspace and sequence: without them the page fails, as it always did.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    libraryID = try container.decode(String.self, forKey: .libraryID)
    cursor = try container.decode(Int64.self, forKey: .cursor)
    hasMore = try container.decode(Bool.self, forKey: .hasMore)
    let read = try container.decode(LossyArray<ExecutionJournalEntry>.self, forKey: .entries)
    entries = read.wrappedValue
    var skips = try container.decodeIfPresent([ExecutionJournalSkip].self, forKey: .skipped) ?? []
    for raw in read.unreadable {
      guard let workspaceID = raw.objectValue?["workspaceID"]?.stringValue,
            let sequence = raw.objectValue?["originSequence"]?.intValue else {
        throw DecodingError.dataCorruptedError(forKey: .entries, in: container,
          debugDescription: "A journal entry has no workspace or sequence.")
      }
      skips.append(.init(workspaceID: workspaceID, originSequence: Int64(sequence)))
    }
    skipped = skips.isEmpty ? nil : skips
  }
}

public struct LibraryArtifactManifest: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var workspaceID: String
  public var title: String
  public var mediaType: String
  public var byteCount: Int64
  public var sha256: String
  public var revision: Int64
  public var deleted: Bool
  public init(id: String, workspaceID: String, title: String, mediaType: String, byteCount: Int64,
              sha256: String, revision: Int64 = 0, deleted: Bool = false) {
    self.id = id; self.workspaceID = workspaceID; self.title = title; self.mediaType = mediaType
    self.byteCount = byteCount; self.sha256 = sha256; self.revision = revision; self.deleted = deleted
  }
}
public struct LibraryArtifactRegistration: Codable, Equatable, Sendable {
  public var manifest: LibraryArtifactManifest
  public var expectedRevision: Int64?
  public init(manifest: LibraryArtifactManifest, expectedRevision: Int64? = nil) {
    self.manifest = manifest; self.expectedRevision = expectedRevision
  }
}
public struct LibraryArtifactTransfer: Codable, Equatable, Sendable {
  public var manifest: LibraryArtifactManifest
  public var nextOffset: Int64
  public var complete: Bool
  public init(manifest: LibraryArtifactManifest, nextOffset: Int64, complete: Bool) {
    self.manifest = manifest; self.nextOffset = nextOffset; self.complete = complete
  }
}
public struct LibraryArtifactChunk: Codable, Equatable, Sendable {
  public var id: String
  public var revision: Int64
  public var offset: Int64
  public var data: Data
  public init(id: String, revision: Int64, offset: Int64, data: Data) {
    self.id = id; self.revision = revision; self.offset = offset; self.data = data
  }
}
public struct LibraryArtifactCommit: Codable, Equatable, Sendable {
  public var id: String
  public var revision: Int64
  public init(id: String, revision: Int64) { self.id = id; self.revision = revision }
}

/// A Linux host's enrolment reply to the Mac that added it: the registered
/// workspace (endpoint and execution device ID) and a device-scoped bearer.
public struct ExecutionCredential: Codable, Equatable, Sendable {
  public var workspace: ExecutionWorkspace
  public var deviceID: String
  public var token: String
  public init(workspace: ExecutionWorkspace, deviceID: String, token: String) {
    self.workspace = workspace; self.deviceID = deviceID; self.token = token
  }
}

/// Complete native message/tool-history records, split without truncation. This
/// stores history, not runtime checkpoints, credentials, or working directories.
public struct NativeRecordPart: Codable, Equatable, Sendable {
  /// A stable identity for this immutable record occurrence across the workspace,
  /// including its conversation/run and revision. A content hash alone is not
  /// an identity: identical tool results can occur in different conversations.
  public var recordID: String
  public var format: String
  public var partIndex: Int
  public var partCount: Int
  public var byteCount: Int64
  public var sha256: String
  public var data: Data
  public init(recordID: String, format: String, partIndex: Int, partCount: Int, byteCount: Int64, sha256: String, data: Data) {
    self.recordID = recordID; self.format = format; self.partIndex = partIndex; self.partCount = partCount
    self.byteCount = byteCount; self.sha256 = sha256; self.data = data
  }
}

/// An idle existing native session moved by the Mac that ran it to a Linux host it added.
/// Sending this value must never replay its historical user messages.
public struct ExecutionAdoption: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var conversation: LibraryConversation
  public var runtimeKind: String
  public var nativeSessionID: String
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var nativeWorkingDirectory: String?
  public var knownRunIDs: [String]?
  public var goal: WorkspaceGoal?
  /// The history the adopting Mac already shows (messages and activities),
  /// so the new owner's transcript starts with it. Sent with the request,
  /// never kept in the saved adoption.
  public var transcript: LibraryTranscript?
  public init(workspaceID: String, conversation: LibraryConversation, runtimeKind: String, nativeSessionID: String,
              model: String? = nil, thinking: String? = nil, permission: String? = nil, knownRunIDs: [String]? = nil, nativeWorkingDirectory: String? = nil, goal: WorkspaceGoal? = nil,
              transcript: LibraryTranscript? = nil) {
    self.transcript = transcript
    self.workspaceID = workspaceID; self.conversation = conversation; self.runtimeKind = runtimeKind
    self.nativeWorkingDirectory = nativeWorkingDirectory
    self.knownRunIDs = knownRunIDs; self.goal = goal
    self.nativeSessionID = nativeSessionID; self.model = model; self.thinking = thinking; self.permission = permission
  }
}
