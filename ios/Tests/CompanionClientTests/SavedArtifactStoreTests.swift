import XCTest
import CryptoKit
import WovenMatterCompanion
@testable import CompanionClient

private actor ArtifactLibrary: FederationTransport {
  var manifest: CompanionArtifactManifest?
  var data = Data()
  var complete = false
  var loseUploadReply = false
  var loseDownloadAt: Int64?
  var downloadOffsets: [Int64] = []
  func configureUploadLoss() { loseUploadReply = true }
  func seed(_ bytes: Data, corruptHash: Bool = false) {
    data = bytes; complete = true
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    manifest = .init(id: "artifact", workspaceID: "phone", title: "Saved", mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: corruptHash ? String(repeating: "0", count: 64) : digest, revision: 1)
  }
  func failDownload(at offset: Int64) { loseDownloadAt = offset }
  func libraryIdentity() throws -> CompanionLibraryIdentity { throw MobileConnectionError.offline }
  func executionWorkspaces() -> [CompanionExecutionWorkspace] { [] }
  func registerWorkspace(_ registration: CompanionWorkspaceRegistration) throws -> CompanionExecutionWorkspace { throw MobileConnectionError.offline }
  func journal(after: Int64) throws -> CompanionJournalPage { throw MobileConnectionError.offline }
  func importJournal(_ batch: CompanionJournalBatch) throws -> CompanionJournalBatchResult { throw MobileConnectionError.offline }
  func artifactManifests() -> [CompanionArtifactManifest] { complete ? manifest.map { [$0] } ?? [] : [] }
  func registerArtifact(_ registration: CompanionArtifactRegistration) -> CompanionArtifactTransfer {
    if manifest == nil { manifest = registration.manifest; manifest!.revision = 1 }
    return .init(manifest: manifest!, nextOffset: Int64(data.count), complete: complete)
  }
  func artifactStatus(_ id: String) -> CompanionArtifactTransfer { .init(manifest: manifest!, nextOffset: Int64(data.count), complete: complete) }
  func uploadArtifactChunk(_ chunk: CompanionArtifactChunk) throws -> CompanionArtifactTransfer {
    guard chunk.offset == data.count else { throw SavedArtifactStore.Failure.invalidTransfer }
    data.append(chunk.data)
    if loseUploadReply { loseUploadReply = false; throw URLError(.networkConnectionLost) }
    return .init(manifest: manifest!, nextOffset: Int64(data.count), complete: false)
  }
  func commitArtifact(_ commit: CompanionArtifactCommit) throws -> CompanionArtifactManifest {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == manifest!.sha256 else { throw SavedArtifactStore.Failure.checksumMismatch }
    complete = true; return manifest!
  }
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) throws -> CompanionArtifactChunk {
    downloadOffsets.append(offset)
    if loseDownloadAt == offset { loseDownloadAt = nil; throw URLError(.networkConnectionLost) }
    let end = min(data.count, Int(offset) + CompanionFederationProtocol.maximumArtifactChunkBytes)
    return .init(id: id, revision: revision, offset: offset, data: data.subdata(in: Int(offset)..<end))
  }
}

final class SavedArtifactStoreTests: XCTestCase {
  private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
  func testLostChunkAcknowledgementResumesAtServerOffsetAfterRestart() async throws {
    let location = directory(); let store = try SavedArtifactStore(directory: location)
    let bytes = Data(repeating: 42, count: 1_200_000)
    let saved = try await store.save(data: bytes, workspaceID: "phone", title: "Output", mediaType: "application/octet-stream")
    let server = ArtifactLibrary(); await server.configureUploadLoss()
    do { try await store.synchronize(using: server); XCTFail() } catch is URLError {}
    let restarted = try SavedArtifactStore(directory: location)
    try await restarted.synchronize(using: server)
    let received = await server.data; XCTAssertEqual(received, bytes)
    let local = await restarted.localURL(id: saved.id); XCTAssertNotNil(local)
    XCTAssertEqual(try Data(contentsOf: local!), bytes)
    let manifests = await restarted.manifests(); XCTAssertEqual(manifests.first?.revision, 1)
  }
  func testPartialDownloadResumesAndIsNotExposedBeforeChecksumVerification() async throws {
    let location = directory(); let store = try SavedArtifactStore(directory: location)
    let bytes = Data(repeating: 85, count: 1_200_000)
    let server = ArtifactLibrary(); await server.seed(bytes); await server.failDownload(at: 1_048_576)
    do { try await store.synchronize(using: server); XCTFail() } catch is URLError {}
    let missing = await store.localURL(id: "artifact"); XCTAssertNil(missing)
    let restarted = try SavedArtifactStore(directory: location)
    try await restarted.synchronize(using: server)
    let downloaded = await restarted.localURL(id: "artifact")
    XCTAssertEqual(try Data(contentsOf: downloaded!), bytes)
    let offsets = await server.downloadOffsets; XCTAssertEqual(offsets, [0, 1_048_576, 1_048_576])
  }
  func testChecksumFailureKeepsFileUnavailableAndResetsResumeOffset() async throws {
    let store = try SavedArtifactStore(directory: directory()); let server = ArtifactLibrary()
    await server.seed(Data("incorrect body".utf8), corruptHash: true)
    for _ in 0..<2 {
      do { try await store.synchronize(using: server); XCTFail() } catch SavedArtifactStore.Failure.checksumMismatch {}
    }
    let local = await store.localURL(id: "artifact"); XCTAssertNil(local)
    let offsets = await server.downloadOffsets; XCTAssertEqual(offsets, [0, 0])
  }
}
