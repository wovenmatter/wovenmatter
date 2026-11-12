import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

public struct PairedMacRoute: Codable, Equatable, Identifiable, Sendable {
  public var id: String { deviceID }
  public let deviceID: String
  public let libraryID: String
  public let endpoint: URL
  public let name: String
  public init(deviceID: String, libraryID: String, endpoint: URL, name: String) {
    self.deviceID = deviceID; self.libraryID = libraryID; self.endpoint = endpoint; self.name = name
  }
  public func validate() throws {
    guard UUID(uuidString: deviceID) != nil, UUID(uuidString: libraryID) != nil,
          PairingPayload.isValidEndpoint(endpoint), !name.isEmpty, name.utf8.count <= 256 else {
      throw LibraryAPIError(code: "invalid_peer", message: "Invalid paired Mac address or identity.")
    }
  }
}
/// The explicitly approved requester learns the issuer's identity and the
/// revocation context it must acknowledge before signing anything.
public struct PairedMacJoinContext: Codable, Sendable, Equatable {
  public let route: PairedMacRoute
  public let publicKey: Data
  public let acknowledgedRevocations: [String]
  public init(route: PairedMacRoute, publicKey: Data, acknowledgedRevocations: [String]) {
    self.route = route; self.publicKey = publicKey; self.acknowledgedRevocations = acknowledgedRevocations
  }
}
/// The requester proves its key for exactly that context, and supplies the
/// bearer it issued for the responder plus the responder's revocation context
/// it knows. The whole transcript is immutable across retries.
public struct PairedMacJoin: Codable, Sendable {
  public let route: PairedMacRoute
  public let returnCredential: String
  public let publicKey: Data
  public let acknowledgedRevocations: [String]
  public let subjectSignature: Data
  public let reciprocalRevocations: [String]
  public init(route: PairedMacRoute, returnCredential: String, publicKey: Data, acknowledgedRevocations: [String],
              subjectSignature: Data, reciprocalRevocations: [String]) {
    self.route = route; self.returnCredential = returnCredential; self.publicKey = publicKey
    self.acknowledgedRevocations = acknowledgedRevocations; self.subjectSignature = subjectSignature
    self.reciprocalRevocations = reciprocalRevocations
  }
}
/// The responder's identity and its subject signature for the reciprocal grant.
public struct PairedMacJoinReply: Codable, Sendable, Equatable {
  public let route: PairedMacRoute
  public let publicKey: Data
  public let subjectSignature: Data
  public init(route: PairedMacRoute, publicKey: Data, subjectSignature: Data) {
    self.route = route; self.publicKey = publicKey; self.subjectSignature = subjectSignature
  }
}
public struct PairedMacExchange: Codable, Sendable {
  public let deviceID: String
  public let after: Int64
  public let page: PairedLibraryPage
  public let membership: PeerMembership
  public init(deviceID: String, after: Int64, page: PairedLibraryPage, membership: PeerMembership) {
    self.deviceID = deviceID; self.after = after; self.page = page; self.membership = membership
  }
}
public struct PairedMacProofChallenge: Codable, Sendable {
  public let deviceID: String
  public let credentialID: String
  public let nonce: Data
  public let targetDeviceID: String
  public let targetLibraryID: String
  public init(deviceID: String, credentialID: String, nonce: Data, targetDeviceID: String, targetLibraryID: String) {
    self.deviceID = deviceID; self.credentialID = credentialID; self.nonce = nonce
    self.targetDeviceID = targetDeviceID; self.targetLibraryID = targetLibraryID
  }
}
public struct PairedMacProof: Codable, Sendable {
  public let route: PairedMacRoute
  public let signature: Data
  public init(route: PairedMacRoute, signature: Data) { self.route = route; self.signature = signature }
}
public struct PairedWorkspaceEnrollment: Codable, Sendable {
  public let workspaceID: String
  public let deviceID: String
  public init(workspaceID: String, deviceID: String) { self.workspaceID = workspaceID; self.deviceID = deviceID }
}

extension WorkspaceDatabase {
  public func savePairedMacRoute(_ route: PairedMacRoute) async throws {
    try route.validate()
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO paired_mac_routes VALUES(?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET library_id=excluded.library_id,endpoint=excluded.endpoint,name=excluded.name", [route.deviceID, route.libraryID, route.endpoint.absoluteString, route.name]) }
  }
  public func pairedMacRoutes() async throws -> [PairedMacRoute] {
    try await read { connection in
      try connection.historyRowsUnlocked("SELECT * FROM paired_mac_routes ORDER BY device_id", values: []).map {
        let row = $0.objectValue!
        guard let endpoint = URL(string: row["endpoint"]!.stringValue!) else { throw WorkspaceDatabaseError.corruptRow }
        let route = PairedMacRoute(deviceID: row["device_id"]!.stringValue!, libraryID: row["library_id"]!.stringValue!, endpoint: endpoint, name: row["name"]!.stringValue!)
        try route.validate(); return route
      }
    }
  }
  public func withdrawUnpairedMac(_ deviceID: String) async throws {
    try await write { connection in
      try connection.transaction {
        guard deviceID != (try connection.libraryIdentityUnlocked().hostDeviceID) else { return }
        for var workspace in try connection.libraryExecutionWorkspaces() where workspace.kind == .mac
            && workspace.ownerDeviceID == deviceID && !workspace.deleted
            && (workspace.endpoint != nil || workspace.retainedHistory != true) {
          workspace.endpoint = nil; workspace.retainedHistory = true; workspace.revision += 1
          let query = try connection.prepareUnlocked("UPDATE execution_workspaces SET revision=?,payload=? WHERE id=?")
          defer { sqlite3_finalize(query) }
          sqlite3_bind_int64(query, 1, workspace.revision)
          try connection.bind(JSONEncoder().encode(workspace), at: 2, to: query)
          try connection.bind(workspace.id, at: 3, to: query); try connection.stepDone(query)
        }
      }
    }
  }

  /// A consistent WAL-aware recovery snapshot precedes the first peer import.
  /// It is never restored automatically over subsequent local writing.
  var peerBackupFile: URL { supportDirectory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite") }

  /// Starts the recovery backup, if this library has none yet, and returns at
  /// once. From now on this library accepts a peer page only once the backup
  /// exists. Copying and checking a library of several gigabytes takes
  /// minutes, so pairing never waits for it: the first synchronization does.
  public func prepareForPeerSync() {
    guard !isReadOnlyProjection else { return }
    let source = fileURL, file = peerBackupFile
    workers.peerBackup.start(file) { try WorkspaceDatabase.writePeerBackup(from: source, to: file) }
  }

  /// Starts the recovery backup if needed and waits for it to finish.
  public func backUpBeforePeerSync() async throws {
    guard !isReadOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let source = fileURL, file = peerBackupFile
    _ = try await workers.peerBackup.wait(file, timeout: nil) { try WorkspaceDatabase.writePeerBackup(from: source, to: file) }
  }

  /// True once a peer page may be imported: the recovery backup exists, or
  /// this library never asked for one (a Linux host). Waits at most `timeout`
  /// for a backup in progress (nil waits until it ends) and throws if it fails.
  public func peerImportsReady(timeout: TimeInterval? = nil) async throws -> Bool {
    let source = fileURL, file = peerBackupFile, fence = workers.peerBackup
    guard !fence.isOpen(file) else { return true }
    return try await fence.wait(file, timeout: timeout) { try WorkspaceDatabase.writePeerBackup(from: source, to: file) }
  }

  var acceptsPeerImports: Bool { workers.peerBackup.isOpen(peerBackupFile) }

  /// A refused peer page while the backup runs. `peer_unavailable` makes the
  /// sending device retry later and show this Mac as offline, not failing.
  public static let peerBackupPending = LibraryAPIError(code: "peer_unavailable",
    message: "This Mac is saving a recovery copy of its library before its first synchronization.")

  /// Copies the library through its own read-only connection, so the writer
  /// and readers keep serving every other job meanwhile. The copy is one
  /// read transaction: the committed library, WAL included, as it was when
  /// the copy began.
  static func writePeerBackup(from source: URL, to file: URL) throws {
    guard !FileManager.default.fileExists(atPath: file.path) else { return }
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let partial = directory.appending(path: UUID().uuidString + ".partial")
    // The copy takes the library's WAL mode until it is switched back, which
    // leaves sidecar files of its own.
    defer { for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: partial.path + suffix) } }
    var library: OpaquePointer?
    guard sqlite3_open_v2(source.path, &library, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let library else {
      sqlite3_close(library); throw WorkspaceDatabaseError.open("Could not read the local library for its recovery backup.")
    }
    defer { sqlite3_close(library) }
    sqlite3_busy_timeout(library, 5_000)
    try WorkspaceDatabaseConnection.copyMainDatabase(from: library, to: partial, openFailure: "Could not create the local recovery backup.",
      copyFailure: "Could not snapshot the local library.", incompleteFailure: "The local recovery backup did not complete.")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
    try FileManager.default.moveItem(at: partial, to: file)
  }
}
