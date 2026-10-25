import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct SavedArtifactLibraryTests {

  @Test func tamperedOpeningCopyIsRebuiltAndUnsafeNamesStayInsideCache() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let bytes = Data("Saved output".utf8)
    let artifact = try await fixture.save(bytes, title: "../../outside/\\report")
    let service = SavedArtifactLibraryService(database: fixture.database)
    let url = try await service.openURL(id: artifact.id, revision: artifact.revision)
    #expect(url.path.hasPrefix(fixture.root.appending(path: "saved-artifact-open").path + "/"))
    #expect(!url.lastPathComponent.contains("/"))
    #expect(!url.lastPathComponent.contains("\\"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try Data("Wrong output".utf8).write(to: url)
    let rebuilt = try await service.openURL(id: artifact.id, revision: artifact.revision)
    #expect(try Data(contentsOf: rebuilt) == bytes)
  }


  @Test func committedRevisionRemainsVisibleDuringUploadAndTombstoneHidesIt() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let artifact = try await fixture.save(Data("before".utf8))
    let service = SavedArtifactLibraryService(database: fixture.database)
    _ = try await service.openURL(id: artifact.id, revision: artifact.revision)
    var replacement = artifact
    let bytes = Data("after".utf8)
    replacement.byteCount = Int64(bytes.count)
    replacement.sha256 = Fixture.hash(bytes)
    let upload = try await fixture.database.registerCompanionArtifact(.init(manifest: replacement, expectedRevision: artifact.revision), deviceID: fixture.deviceID)
    #expect(try await service.items().first?.manifest == artifact)
    _ = try await fixture.database.appendCompanionArtifactChunk(.init(id: artifact.id, revision: upload.manifest.revision, offset: 0, data: bytes), deviceID: fixture.deviceID)
    var saved = try await fixture.database.commitCompanionArtifact(.init(id: artifact.id, revision: upload.manifest.revision), deviceID: fixture.deviceID)
    await #expect(throws: (any Error).self) { try await service.openURL(id: artifact.id, revision: artifact.revision) }
    #expect(try Data(contentsOf: await service.openURL(id: saved.id, revision: saved.revision)) == bytes)
    saved.deleted = true
    _ = try await fixture.database.registerCompanionArtifact(.init(manifest: saved, expectedRevision: saved.revision), deviceID: fixture.deviceID)
    #expect(try await service.items().isEmpty)
    await #expect(throws: (any Error).self) { try await service.openURL(id: saved.id, revision: saved.revision) }
  }

  private struct Fixture {
    let root: URL
    let database: WorkspaceDatabase
    let workspaceID: String
    let deviceID: String
    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      let identity = try await database.companionLibraryIdentity()
      deviceID = UUID().uuidString.lowercased()
      workspaceID = UUID().uuidString.lowercased()
      _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(id: workspaceID, libraryID: identity.libraryID, ownerDeviceID: deviceID, kind: .ios, name: "My iPhone")), deviceID: deviceID)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func save(_ bytes: Data, title: String = "Output.txt") async throws -> CompanionArtifactManifest {
      let manifest = CompanionArtifactManifest(id: UUID().uuidString.lowercased(), workspaceID: workspaceID, title: title, mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: Self.hash(bytes))
      let transfer = try await database.registerCompanionArtifact(.init(manifest: manifest), deviceID: deviceID)
      for offset in stride(from: 0, to: bytes.count, by: CompanionFederationProtocol.maximumArtifactChunkBytes) {
        let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + CompanionFederationProtocol.maximumArtifactChunkBytes))
        _ = try await database.appendCompanionArtifactChunk(.init(id: manifest.id, revision: transfer.manifest.revision, offset: Int64(offset), data: chunk), deviceID: deviceID)
      }
      return try await database.commitCompanionArtifact(.init(id: manifest.id, revision: transfer.manifest.revision), deviceID: deviceID)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  }
}
