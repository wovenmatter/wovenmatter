import Foundation

/// Additive federation capability: legacy companion v3 records remain unchanged.
public enum CompanionFederationProtocol {
  public static let version = 1
  public static let capability = "library.federation.v1"
  public static let maximumBatchEntries = 200
  public static let maximumBatchBytes = 8 * 1_024 * 1_024
  public static let maximumArtifactChunkBytes = 1_024 * 1_024
}

public struct CompanionLibraryIdentity: Codable, Equatable, Sendable {
  public var libraryID: String
  public var hostDeviceID: String
  public var protocolVersion: Int
  public init(libraryID: String, hostDeviceID: String, protocolVersion: Int = CompanionFederationProtocol.version) {
    self.libraryID = libraryID; self.hostDeviceID = hostDeviceID; self.protocolVersion = protocolVersion
  }
}

public struct CompanionExecutionWorkspace: Codable, Equatable, Identifiable, Sendable {
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
  /// Only the owner and these explicitly granted devices may submit origin history.
  public var journalDeviceIDs: [String]
  public var revision: Int64
  public var deleted: Bool
  public init(id: String, libraryID: String, ownerDeviceID: String, kind: Kind, name: String,
              endpoint: URL? = nil, capabilities: [String] = [], executionDeviceID: String? = nil, journalDeviceIDs: [String] = [], revision: Int64 = 0, deleted: Bool = false) {
    self.id = id; self.libraryID = libraryID; self.ownerDeviceID = ownerDeviceID; self.kind = kind; self.name = name
    self.executionDeviceID = executionDeviceID
    self.endpoint = endpoint; self.capabilities = capabilities; self.journalDeviceIDs = journalDeviceIDs
    self.revision = revision; self.deleted = deleted
  }
}
public struct CompanionWorkspaceRegistration: Codable, Equatable, Sendable {
  public var workspace: CompanionExecutionWorkspace
  public var expectedRevision: Int64?
  public init(workspace: CompanionExecutionWorkspace, expectedRevision: Int64? = nil) {
    self.workspace = workspace; self.expectedRevision = expectedRevision
  }
}

/// Immutable records emitted by one execution owner. Runtime checkpoints and
/// working files are intentionally excluded. Importing a receipt never executes it.
public struct CompanionJournalEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case conversation, transcript, receipt, deletedConversation, restoredConversation, nativeRecord }
  public var id: String { eventID }
  public var eventID: String
  public var workspaceID: String
  public var originSequence: Int64
  public var conversationID: String
  public var runID: String?
  public var kind: Kind
  public var conversation: CompanionConversation?
  public var transcript: CompanionTranscript?
  public var receipt: CompanionCommandReceipt?
  public var nativeRecord: CompanionNativeRecordPart?
  public init(eventID: String = UUID().uuidString.lowercased(), workspaceID: String, originSequence: Int64,
              conversationID: String, runID: String? = nil, kind: Kind,
              conversation: CompanionConversation? = nil, transcript: CompanionTranscript? = nil, receipt: CompanionCommandReceipt? = nil, nativeRecord: CompanionNativeRecordPart? = nil) {
    self.eventID = eventID; self.workspaceID = workspaceID; self.originSequence = originSequence
    self.conversationID = conversationID; self.runID = runID; self.kind = kind
    self.nativeRecord = nativeRecord
    self.conversation = conversation; self.transcript = transcript; self.receipt = receipt
  }
}
public struct CompanionJournalBatch: Codable, Equatable, Sendable {
  public var libraryID: String
  public var entries: [CompanionJournalEntry]
  public init(libraryID: String, entries: [CompanionJournalEntry]) { self.libraryID = libraryID; self.entries = entries }
}
public struct CompanionJournalBatchResult: Codable, Equatable, Sendable {
  public var libraryID: String
  public var acceptedEventIDs: [String]
  public var cursor: Int64
  public init(libraryID: String, acceptedEventIDs: [String], cursor: Int64) {
    self.libraryID = libraryID; self.acceptedEventIDs = acceptedEventIDs; self.cursor = cursor
  }
}
public struct CompanionJournalPage: Codable, Equatable, Sendable {
  public var libraryID: String
  /// Central-library cursor; unrelated to any workspace's originSequence.
  public var cursor: Int64
  public var entries: [CompanionJournalEntry]
  public var hasMore: Bool
  public init(libraryID: String, cursor: Int64, entries: [CompanionJournalEntry] = [], hasMore: Bool = false) {
    self.libraryID = libraryID; self.cursor = cursor; self.entries = entries; self.hasMore = hasMore
  }
}

public struct CompanionArtifactManifest: Codable, Equatable, Identifiable, Sendable {
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
public struct CompanionArtifactRegistration: Codable, Equatable, Sendable {
  public var manifest: CompanionArtifactManifest
  public var expectedRevision: Int64?
  public init(manifest: CompanionArtifactManifest, expectedRevision: Int64? = nil) {
    self.manifest = manifest; self.expectedRevision = expectedRevision
  }
}
public struct CompanionArtifactTransfer: Codable, Equatable, Sendable {
  public var manifest: CompanionArtifactManifest
  public var nextOffset: Int64
  public var complete: Bool
  public init(manifest: CompanionArtifactManifest, nextOffset: Int64, complete: Bool) {
    self.manifest = manifest; self.nextOffset = nextOffset; self.complete = complete
  }
}
public struct CompanionArtifactChunk: Codable, Equatable, Sendable {
  public var id: String
  public var revision: Int64
  public var offset: Int64
  public var data: Data
  public init(id: String, revision: Int64, offset: Int64, data: Data) {
    self.id = id; self.revision = revision; self.offset = offset; self.data = data
  }
}
public struct CompanionArtifactCommit: Codable, Equatable, Sendable {
  public var id: String
  public var revision: Int64
  public init(id: String, revision: Int64) { self.id = id; self.revision = revision }
}

/// A device-scoped bearer returned only by authenticated central provisioning.
public struct CompanionExecutionCredential: Codable, Equatable, Sendable {
  public var workspace: CompanionExecutionWorkspace
  public var deviceID: String
  public var token: String
  public init(workspace: CompanionExecutionWorkspace, deviceID: String, token: String) {
    self.workspace = workspace; self.deviceID = deviceID; self.token = token
  }
}

/// Complete native message/tool-history records, split without truncation. This
/// stores history, not runtime checkpoints, credentials, or working directories.
public struct CompanionNativeRecordPart: Codable, Equatable, Sendable {
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

/// A secondary execution host delegates device provisioning to its central
/// library. The secret belongs in protected storage, never the sync journal.
public struct CompanionExecutionManagementGrant: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var endpoint: URL
  public var token: String
  public init(workspaceID: String, endpoint: URL, token: String) {
    self.workspaceID = workspaceID; self.endpoint = endpoint; self.token = token
  }
}

/// An idle existing native session transferred by its trusted central manager.
/// Sending this value must never replay its historical user messages.
public struct CompanionExecutionAdoption: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var conversation: CompanionConversation
  public var runtimeKind: String
  public var nativeSessionID: String
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var knownRunIDs: [String]?
  public init(workspaceID: String, conversation: CompanionConversation, runtimeKind: String, nativeSessionID: String,
              model: String? = nil, thinking: String? = nil, permission: String? = nil, knownRunIDs: [String]? = nil) {
    self.workspaceID = workspaceID; self.conversation = conversation; self.runtimeKind = runtimeKind
    self.knownRunIDs = knownRunIDs
    self.nativeSessionID = nativeSessionID; self.model = model; self.thinking = thinking; self.permission = permission
  }
}
