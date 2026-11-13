import WorkspaceFixtures
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

struct SavedArtifactLibraryTests {

  @Test func tamperedOpeningCopyIsRebuiltAndUnsafeNamesStayInsideCache() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let bytes = Data("Saved output".utf8)
    let artifact = try await fixture.save(bytes, title: "../../outside/\\report")
    let service = SavedArtifactLibraryService(database: fixture.database)
    let url = try await service.openURL(id: artifact.id, revision: artifact.revision)
    #expect(url.path.hasPrefix(fixture.persistence.directory.appending(path: "saved-artifact-open").path + "/"))
    #expect(!url.lastPathComponent.contains("/"))
    #expect(!url.lastPathComponent.contains("\\"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try Data("Wrong output".utf8).write(to: url)
    let rebuilt = try await service.openURL(id: artifact.id, revision: artifact.revision)
    #expect(try Data(contentsOf: rebuilt) == bytes)
  }



  private struct Fixture {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let workspaceID: String
    let deviceID: String
    init() async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      let identity = try await database.libraryIdentity()
      deviceID = UUID().uuidString.lowercased()
      workspaceID = UUID().uuidString.lowercased()
      _ = try await database.registerExecutionWorkspace(.init(workspace: .init(id: workspaceID, libraryID: identity.libraryID, ownerDeviceID: deviceID, kind: .ios, name: "My iPhone")), deviceID: deviceID)
    }
    func remove() { persistence.remove() }
    func save(_ bytes: Data, title: String = "Output.txt") async throws -> LibraryArtifactManifest {
      let manifest = LibraryArtifactManifest(id: UUID().uuidString.lowercased(), workspaceID: workspaceID, title: title, mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: Self.hash(bytes))
      let transfer = try await database.registerLibraryArtifact(.init(manifest: manifest), deviceID: deviceID)
      for offset in stride(from: 0, to: bytes.count, by: FederationProtocol.maximumArtifactChunkBytes) {
        let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + FederationProtocol.maximumArtifactChunkBytes))
        _ = try await database.appendLibraryArtifactChunk(.init(id: manifest.id, revision: transfer.manifest.revision, offset: Int64(offset), data: chunk), deviceID: deviceID)
      }
      return try await database.commitLibraryArtifact(.init(id: manifest.id, revision: transfer.manifest.revision), deviceID: deviceID)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).hexString }
  }
}
