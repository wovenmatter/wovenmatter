import CryptoKit
import Foundation
import WovenMatterCore

/// Persistent destination half of a transfer. Approval is local-only; possession
/// of a request ID, tailnet discovery, or an unapproved secret cannot upload data.
public actor LibraryTransferReceiver {
  public struct Session: Codable, Sendable {
    public var request: CompanionLibraryTransferRequest
    public var status: CompanionLibraryTransferStatus
    public var manifest: CompanionLibraryTransferManifest?
    public var result: LibraryTransferSQLite.MergeResult?
  }
  private let root: URL
  private var sessions: [String: Session] = [:]
  private var busy = Set<String>()
  public init(directory: URL) throws {
    root = directory
    if FileManager.default.fileExists(atPath: directory.path) {
      for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let file = folder.appending(path: "session.json")
        if FileManager.default.fileExists(atPath: file.path) {
          let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: file))
          guard UUID(uuidString: session.request.id) != nil, folder.lastPathComponent == session.request.id else { throw invalid }
          sessions[session.request.id] = session
        }
      }
    }
  }
  public func allSessions() -> [Session] { sessions.values.sorted { $0.request.id < $1.request.id } }
  private func folder(_ id: String) -> URL { root.appending(path: id) }
  private func save(_ session: Session) throws {
    try LibraryTransferArchive.persist(session, to: folder(session.request.id).appending(path: "session.json"))
    sessions[session.request.id] = session
  }
  public func request(_ request: CompanionLibraryTransferRequest, destinationDeviceID: String) throws -> CompanionLibraryTransferStatus {
    guard UUID(uuidString: request.id) != nil, UUID(uuidString: request.source.deviceID) != nil,
          UUID(uuidString: request.sourceLibraryID) != nil, request.destinationDeviceID == destinationDeviceID,
          request.source.deviceID != destinationDeviceID, request.source.metadata.kind == .mac,
          request.source.deviceName.utf8.count <= 120, !request.source.deviceName.isEmpty,
          !request.source.deviceName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          CompanionPairingPayload.isValidEndpoint(request.sourceEndpoint), request.secretDigest.count == 64,
          request.secretDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
    if let prior = sessions[request.id] {
      guard prior.request == request else { throw invalid }; return prior.status
    }
    guard sessions.values.filter({ ![.cancelled, .committed].contains($0.status.phase) }).count < 4 else {
      throw CompanionAPIError(code: "transfer_busy", message: "Review or dismiss the pending database transfer on the destination Mac.")
    }
    let session = Session(request: request, status: .init(id: request.id, phase: .awaitingApproval))
    try save(session); return session.status
  }
  public func authenticated(_ id: String, secret: String) throws -> Session {
    guard secret.utf8.count >= 32, secret.utf8.count <= 256, let session = sessions[id] else { throw invalid }
    let digest = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    guard zip(digest.utf8, session.request.secretDigest.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { throw invalid }
    return session
  }
  public func approve(_ id: String, database: WorkspaceDatabase, endpoint: URL,
                      additionalBackup: @Sendable (URL) async throws -> Void = { _ in }) async throws {
    guard var session = sessions[id], session.status.phase == .awaitingApproval,
          !sessions.values.contains(where: { $0.request.id != id && [.receiving, .verified].contains($0.status.phase) }),
          !busy.contains(id) else { throw invalid }
    busy.insert(id); defer { busy.remove(id) }
    guard CompanionPairingPayload.isValidEndpoint(endpoint) else { throw invalid }
    try await database.fenceLibraryTransfer(id)
    do {
      let backup = folder(id).appending(path: "destination-backup/" + UUID().uuidString)
      try await LibraryTransferArchive.backup(database: database, to: backup)
      try await additionalBackup(backup)
      // Device authorization is part of authority handoff, not library content.
      let deviceFile = database.supportDirectory.appending(path: "companion-devices.json")
      if FileManager.default.fileExists(atPath: deviceFile.path), !FileManager.default.fileExists(atPath: backup.appending(path: "companion-devices.json").path) {
        try FileManager.default.copyItem(at: deviceFile, to: backup.appending(path: "companion-devices.json"))
      }
      session.status.phase = .receiving; session.status.backupPath = backup.path
      session.status.destinationEndpoint = endpoint
      session.status.destinationLibraryID = try await database.companionWorkspaceID()
      try save(session)
    } catch { try? await database.releaseLibraryTransfer(id); throw error }
  }
  public func setManifest(_ manifest: CompanionLibraryTransferManifest, id: String, secret: String) throws -> CompanionLibraryTransferStatus {
    var session = try authenticated(id, secret: secret)
    if busy.contains(id) { throw transferBusy }
    guard session.status.phase == .receiving, !busy.contains(id), manifest.transferID == id,
          manifest.libraryID == session.request.sourceLibraryID else { throw invalid }
    try LibraryTransferArchive.validate(manifest)
    guard Set(["workspace.sqlite", "devices.json", "authority.json", "lineage.json"]).isSubset(of: Set(manifest.files.map(\.path))) else { throw invalid }
    if let previous = session.manifest { guard previous == manifest else { throw invalid } }
    session.manifest = manifest
    let incoming = folder(id).appending(path: "incoming")
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Empty files have no chunk to upload, but still participate in verification.
    for file in manifest.files where file.byteCount == 0 {
      let url = try LibraryTransferArchive.secureFile(file.path, in: incoming, createParents: true)
      if !FileManager.default.fileExists(atPath: url.path) { try LibraryTransferArchive.persist(Data(), to: url) }
    }
    try save(session); return session.status
  }
  public func upload(_ chunk: CompanionLibraryTransferChunk, id: String, secret: String) throws -> CompanionLibraryTransferStatus {
    var session = try authenticated(id, secret: secret)
    guard session.status.phase == .receiving, !busy.contains(id), let manifest = session.manifest else { throw invalid }
    let next = try LibraryTransferArchive.write(chunk, manifest: manifest, in: folder(id).appending(path: "incoming"))
    session.status.offsets[chunk.path] = next
    try save(session); return session.status
  }
  public func verify(_ id: String, secret: String) async throws -> CompanionLibraryTransferStatus {
    var session = try authenticated(id, secret: secret)
    if [.verified, .committed].contains(session.status.phase) { return session.status }
    if busy.contains(id) { throw transferBusy }
    guard session.status.phase == .receiving, let manifest = session.manifest, let backup = session.status.backupPath,
          let libraryID = session.status.destinationLibraryID, !busy.contains(id) else { throw invalid }
    busy.insert(id); defer { busy.remove(id) }
    let incoming = folder(id).appending(path: "incoming"), staging = folder(id).appending(path: "merged.sqlite")
    let expected = session.request
    let result = try await Task.detached(priority: .utility) {
      try LibraryTransferArchive.verify(manifest: manifest, in: incoming)
      let identity = try LibraryTransferSQLite.identity(incoming.appending(path: "workspace.sqlite"))
      guard identity.libraryID == expected.sourceLibraryID, identity.hostDeviceID == expected.source.deviceID else {
        throw CompanionAPIError(code: "transfer_identity", message: "The received database does not belong to the Mac approved for this transfer.")
      }
      let devices = try JSONDecoder().decode([CompanionPairedDevice].self, from: Data(contentsOf: incoming.appending(path: "devices.json")))
      try CompanionAuthentication.validateTransferredDevices(devices)
      let grants = try JSONDecoder().decode([CompanionExecutionManagementGrant].self, from: Data(contentsOf: incoming.appending(path: "authority.json")))
      guard grants.count <= 4096, grants.allSatisfy({ UUID(uuidString: $0.workspaceID) != nil && (32...256).contains($0.token.utf8.count) && $0.endpoint.scheme == "https" && $0.endpoint.host?.hasSuffix(".ts.net") == true && $0.endpoint.user == nil && $0.endpoint.password == nil && $0.endpoint.query == nil && $0.endpoint.fragment == nil }) else {
        throw CompanionAPIError(code: "transfer_authority", message: "The transferred workspace management records are invalid.")
      }
      let aliases = try JSONDecoder().decode([CompanionLibraryRelocation].self, from: Data(contentsOf: incoming.appending(path: "lineage.json")))
      guard aliases.count <= 4096, aliases.allSatisfy({ UUID(uuidString: $0.previousLibraryID) != nil }) else {
        throw CompanionAPIError(code: "transfer_lineage", message: "The transferred library identities are invalid.")
      }
      // A failed/interrupted verification always rebuilds from the immutable
      // destination backup. It cannot compound a half-finished merge.
      for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: staging.path + suffix) }
      try LibraryTransferSQLite.snapshot(URL(fileURLWithPath: backup).appending(path: "workspace.sqlite"), to: staging)
      return try LibraryTransferSQLite.merge(source: incoming.appending(path: "workspace.sqlite"), into: staging,
        transferID: id, sourceLibraryID: manifest.libraryID, destinationLibraryID: libraryID)
    }.value
    session.result = result; session.status.phase = .verified
    session.status.recoveredItemCount = result.recoveredItems; session.status.retainedConflictCount = result.retainedConflicts
    try save(session); return session.status
  }
  public func commit(_ id: String, secret: String, database: WorkspaceDatabase,
                     authentication: CompanionAuthentication) async throws -> CompanionLibraryTransferStatus {
    var session = try authenticated(id, secret: secret)
    if session.status.phase == .committed { return session.status }
    if busy.contains(id) { throw transferBusy }
    guard session.status.phase == .verified, let manifest = session.manifest, !busy.contains(id) else { throw invalid }
    busy.insert(id); defer { busy.remove(id) }
    try await database.fenceLibraryTransfer(id)
    let incoming = folder(id).appending(path: "incoming")
    try LibraryTransferArchive.verify(manifest: manifest, in: incoming)
    // Immutable blobs may be installed before the SQL commit: an unreferenced
    // blob is harmless; an accepted row referencing a missing blob is not.
    try LibraryTransferArchive.installAssets(from: incoming, to: database.supportDirectory, manifest: manifest)
    let devices = try JSONDecoder().decode([CompanionPairedDevice].self, from: Data(contentsOf: incoming.appending(path: "devices.json")))
    // Authorization records and data have independent durable commits. Retrying
    // this exact operation is idempotent on both sides; no source role can resume
    // after it has issued commit, even if this reply is lost.
    try await authentication.mergeTransferredDevices(devices)
    let bootstrap = SHA256.hash(data: Data(("woven-library-node-v1\0" + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    try await authentication.provisionTransferredHost(deviceID: session.request.source.deviceID, name: session.request.source.deviceName, token: bootstrap)
    try await database.activateTransferredLibrary(from: folder(id).appending(path: "merged.sqlite"), transferID: id)
    session.status.phase = .committed; try save(session)
    try await database.releaseLibraryTransfer(id)
    return session.status
  }
  public func cancel(_ id: String, database: WorkspaceDatabase?) async throws {
    guard var session = sessions[id], session.status.phase != .committed, !busy.contains(id) else { throw invalid }
    session.status.phase = .cancelled; try save(session)
    try await database?.releaseLibraryTransfer(id)
  }
  public func restoreFences(database: WorkspaceDatabase) async throws {
    for session in sessions.values where [.receiving, .verified].contains(session.status.phase) { try await database.fenceLibraryTransfer(session.request.id) }
  }
  public func incomingDirectory(_ id: String) throws -> URL { guard sessions[id] != nil else { throw invalid }; return folder(id).appending(path: "incoming") }
  private nonisolated var invalid: CompanionAPIError { .init(code: "invalid_transfer", message: "The database transfer is unavailable, unapproved, or no longer current.") }
  private nonisolated var transferBusy: CompanionAPIError { .init(code: "transfer_busy", message: "The destination is still verifying or activating the saved transfer. It will resume automatically.") }
}
