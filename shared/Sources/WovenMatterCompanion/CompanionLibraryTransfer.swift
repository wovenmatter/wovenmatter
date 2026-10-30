import Foundation

/// A library move is a durable two-party transaction. Execution ownership is
/// independent: transferring library storage never transfers an agent runtime.
public enum CompanionLibraryTransferPhase: String, Codable, Sendable {
  case awaitingApproval, receiving, verified, committed, cancelled
}

public struct CompanionLibraryTransferRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let source: CompanionPairingDeviceIdentity
  public let sourceEndpoint: URL
  public let sourceLibraryID: String
  public let destinationDeviceID: String
  public let secretDigest: String
  public init(id: String, source: CompanionPairingDeviceIdentity, sourceEndpoint: URL,
              sourceLibraryID: String, destinationDeviceID: String, secretDigest: String) {
    self.id = id; self.source = source; self.sourceEndpoint = sourceEndpoint
    self.sourceLibraryID = sourceLibraryID; self.destinationDeviceID = destinationDeviceID
    self.secretDigest = secretDigest
  }
}

public struct CompanionLibraryTransferFile: Codable, Equatable, Sendable {
  public let path: String
  public let byteCount: Int64
  public let sha256: String
  public init(path: String, byteCount: Int64, sha256: String) {
    self.path = path; self.byteCount = byteCount; self.sha256 = sha256
  }
}

public struct CompanionLibraryTransferManifest: Codable, Equatable, Sendable {
  public static let version = 1
  public let version: Int
  public let transferID: String
  public let libraryID: String
  public let files: [CompanionLibraryTransferFile]
  public init(transferID: String, libraryID: String, files: [CompanionLibraryTransferFile]) {
    version = Self.version; self.transferID = transferID; self.libraryID = libraryID; self.files = files
  }
}

public struct CompanionLibraryTransferStatus: Codable, Equatable, Sendable {
  public let id: String
  public var phase: CompanionLibraryTransferPhase
  public var offsets: [String: Int64]
  public var destinationEndpoint: URL?
  public var destinationLibraryID: String?
  public var backupPath: String?
  public var error: String?
  public var readyForClients: Bool? = nil
  public var recoveredItemCount: Int? = nil
  public var retainedConflictCount: Int? = nil
  public init(id: String, phase: CompanionLibraryTransferPhase, offsets: [String: Int64] = [:],
              destinationEndpoint: URL? = nil, destinationLibraryID: String? = nil,
              backupPath: String? = nil, error: String? = nil) {
    self.id = id; self.phase = phase; self.offsets = offsets; self.destinationEndpoint = destinationEndpoint
    self.destinationLibraryID = destinationLibraryID; self.backupPath = backupPath; self.error = error
  }
}

public struct CompanionLibraryTransferChunk: Codable, Sendable {
  public let path: String
  public let offset: Int64
  public let data: Data
  public init(path: String, offset: Int64, data: Data) { self.path = path; self.offset = offset; self.data = data }
}

/// An authenticated old endpoint or a proof made with a transferred device
/// credential digest authorizes this route. Discovery alone never authorizes it.
public struct CompanionLibraryRelocation: Codable, Equatable, Sendable {
  public let transferID: String
  public let previousLibraryID: String
  public let endpoint: URL
  public let libraryID: String
  public init(transferID: String, previousLibraryID: String, endpoint: URL, libraryID: String) {
    self.transferID = transferID; self.previousLibraryID = previousLibraryID
    self.endpoint = endpoint; self.libraryID = libraryID
  }
}

public struct CompanionLibraryMoved: Codable, Sendable {
  public let code: String
  public let relocation: CompanionLibraryRelocation
  public init(_ relocation: CompanionLibraryRelocation) { self.code = "library_moved"; self.relocation = relocation }
}

public struct CompanionLibraryRelocationChallenge: Codable, Sendable {
  public let libraryID: String
  public let deviceID: String
  public let nonce: Data
  public let credentialID: String?
  public init(libraryID: String, deviceID: String, nonce: Data, credentialID: String? = nil) { self.libraryID = libraryID; self.deviceID = deviceID; self.nonce = nonce; self.credentialID = credentialID }
}

public struct CompanionLibraryRelocationProof: Codable, Sendable {
  public let relocation: CompanionLibraryRelocation
  public let signature: Data
  public init(relocation: CompanionLibraryRelocation, signature: Data) { self.relocation = relocation; self.signature = signature }
}
