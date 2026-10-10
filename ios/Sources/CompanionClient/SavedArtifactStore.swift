import Foundation
import CryptoKit
import WovenMatterCompanion

/// Explicit library saves only. Repositories and runtime checkpoint files never
/// enter this store. A partial download is not exposed until SHA-256 verification.
public actor SavedArtifactStore {
  private struct Record: Codable, Equatable {
    var manifest: CompanionArtifactManifest
    var upload: Bool
    var downloadedBytes: Int64
    var complete: Bool
  }
  private struct State: Codable, Equatable { var records: [String: Record] = [:] }
  public enum Failure: Error, LocalizedError {
    case invalidTransfer, checksumMismatch, capacity
    public var errorDescription: String? {
      switch self {
      case .invalidTransfer: "The saved artifact transfer is inconsistent. The existing file has been retained."
      case .checksumMismatch: "The saved artifact did not match its checksum. It has not been opened."
      case .capacity: "This artifact exceeds the local saved-file storage limit."
      }
    }
  }
  public static let maximumArtifactBytes: Int64 = 256 * 1_024 * 1_024
  private static let maximumStoreBytes: Int64 = 1_024 * 1_024 * 1_024
  private let directory: URL
  private var state: State
  private var syncTask: Task<Void, Error>?
  public init(directory: URL) throws {
    self.directory = directory
    let file = directory.appendingPathComponent("index.json")
    state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : .init()
  }
  public func manifests() -> [CompanionArtifactManifest] { state.records.values.map(\.manifest) }
  public func localURL(id: String) -> URL? {
    guard let record = state.records[id], record.complete, !record.manifest.deleted else { return nil }
    return blob(record.manifest)
  }
  @discardableResult public func save(data: Data, workspaceID: String, title: String, mediaType: String, id: String = UUID().uuidString.lowercased()) throws -> CompanionArtifactManifest {
    guard state.records[id] == nil else { throw Failure.invalidTransfer }
    let manifest = CompanionArtifactManifest(id: id, workspaceID: workspaceID, title: title, mediaType: mediaType,
      byteCount: Int64(data.count), sha256: Self.digest(data))
    try validate(manifest)
    try MobileStorePersistence.writeDurably(data, at: blob(manifest))
    try update(id, Record(manifest: manifest, upload: true, downloadedBytes: manifest.byteCount, complete: true))
    return manifest
  }
  public func synchronize(using transport: any FederationTransport) async throws {
    if let syncTask { return try await syncTask.value }
    let task = Task { try await self.performSynchronization(using: transport) }; syncTask = task
    defer { syncTask = nil }; try await task.value
  }
  private func performSynchronization(using transport: any FederationTransport) async throws {
    for original in state.records.values.filter(\.upload) {
      var transfer = try await transport.registerArtifact(.init(manifest: original.manifest,
        expectedRevision: original.manifest.revision > 0 ? original.manifest.revision : nil))
      try validateTransfer(transfer, original: original.manifest)
      let source = try FileHandle(forReadingFrom: blob(original.manifest)); defer { try? source.close() }
      while !transfer.complete && transfer.nextOffset < original.manifest.byteCount {
        try Task.checkCancellation()
        try source.seek(toOffset: UInt64(transfer.nextOffset))
        let count = Int(min(Int64(CompanionFederationProtocol.maximumArtifactChunkBytes), original.manifest.byteCount - transfer.nextOffset))
        guard let data = try source.read(upToCount: count), data.count == count else { throw Failure.invalidTransfer }
        let next = try await transport.uploadArtifactChunk(.init(id: transfer.manifest.id, revision: transfer.manifest.revision, offset: transfer.nextOffset, data: data))
        try validateTransfer(next, original: original.manifest)
        guard next.nextOffset == transfer.nextOffset + Int64(data.count) else { throw Failure.invalidTransfer }
        transfer = next
      }
      let committed = transfer.complete ? transfer.manifest : try await transport.commitArtifact(.init(id: transfer.manifest.id, revision: transfer.manifest.revision))
      guard Self.sameContent(committed, original.manifest), committed.revision > 0 else { throw Failure.invalidTransfer }
      try update(committed.id, .init(manifest: committed, upload: false, downloadedBytes: committed.byteCount, complete: true))
    }
    for manifest in try await transport.artifactManifests() {
      if state.records[manifest.id]?.upload == true { continue }
      if let current = state.records[manifest.id], current.manifest.revision > manifest.revision { continue }
      try validate(manifest)
      if manifest.deleted {
        try update(manifest.id, .init(manifest: manifest, upload: false, downloadedBytes: 0, complete: true)); continue
      }
      if let current = state.records[manifest.id], current.manifest == manifest, current.complete { continue }
      var record = state.records[manifest.id]
      if record?.manifest != manifest {
        record = .init(manifest: manifest, upload: false, downloadedBytes: 0, complete: false)
        try update(manifest.id, record!)
      }
      let partial = part(manifest)
      if !FileManager.default.fileExists(atPath: partial.path) { try MobileStorePersistence.writeDurably(Data(), at: partial) }
      let handle = try FileHandle(forWritingTo: partial); defer { try? handle.close() }
      // A crash after fsync but before index replacement can leave an extra chunk.
      // Roll back those unacknowledged bytes before requesting the same offset.
      try handle.truncate(atOffset: UInt64(record!.downloadedBytes)); try handle.seekToEnd()
      while record!.downloadedBytes < manifest.byteCount {
        try Task.checkCancellation()
        let chunk = try await transport.downloadArtifactChunk(manifest.id, revision: manifest.revision, offset: record!.downloadedBytes)
        guard chunk.id == manifest.id, chunk.revision == manifest.revision, chunk.offset == record!.downloadedBytes,
          !chunk.data.isEmpty, chunk.data.count <= CompanionFederationProtocol.maximumArtifactChunkBytes,
          chunk.offset + Int64(chunk.data.count) <= manifest.byteCount else { throw Failure.invalidTransfer }
        try handle.write(contentsOf: chunk.data); try handle.synchronize()
        record!.downloadedBytes += Int64(chunk.data.count); try update(manifest.id, record!)
      }
      let downloaded = try Data(contentsOf: partial, options: .mappedIfSafe)
      guard Int64(downloaded.count) == manifest.byteCount, Self.digest(downloaded) == manifest.sha256 else {
        record!.downloadedBytes = 0; try update(manifest.id, record!); throw Failure.checksumMismatch
      }
      try MobileStorePersistence.writeDurably(downloaded, at: blob(manifest))
      record!.complete = true; try update(manifest.id, record!)
      try? FileManager.default.removeItem(at: partial)
    }
  }
  private func validate(_ manifest: CompanionArtifactManifest) throws {
    guard !manifest.id.isEmpty, manifest.sha256.count == 64,
      manifest.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), manifest.byteCount >= 0,
      manifest.byteCount <= Self.maximumArtifactBytes else { throw Failure.capacity }
    let current = state.records.values.filter { $0.manifest.id != manifest.id && !$0.manifest.deleted }.reduce(Int64(0)) { $0 + $1.manifest.byteCount }
    guard current + manifest.byteCount <= Self.maximumStoreBytes else { throw Failure.capacity }
  }
  private func validateTransfer(_ transfer: CompanionArtifactTransfer, original: CompanionArtifactManifest) throws {
    guard Self.sameContent(transfer.manifest, original), transfer.manifest.revision > 0,
      transfer.nextOffset >= 0, transfer.nextOffset <= original.byteCount,
      !transfer.complete || transfer.nextOffset == original.byteCount else { throw Failure.invalidTransfer }
  }
  private static func sameContent(_ a: CompanionArtifactManifest, _ b: CompanionArtifactManifest) -> Bool {
    a.id == b.id && a.workspaceID == b.workspaceID && a.sha256 == b.sha256 && a.byteCount == b.byteCount && a.deleted == b.deleted && a.title == b.title && a.mediaType == b.mediaType
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func blob(_ manifest: CompanionArtifactManifest) -> URL { directory.appendingPathComponent(manifest.sha256 + ".blob") }
  private func part(_ manifest: CompanionArtifactManifest) -> URL { directory.appendingPathComponent(Self.digest(Data((manifest.id + ":" + String(manifest.revision)).utf8)) + ".partial") }
  private func update(_ id: String, _ record: Record) throws {
    var next = state; next.records[id] = record
    try MobileStorePersistence.writeDurably(JSONEncoder().encode(next), at: directory.appendingPathComponent("index.json")); state = next
  }
}
