import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Execution workspace roots")
struct WorkspaceExecutionRootTests {

  @Test(arguments: [false, true])
  func folderReorderingStaysWithinItsWorkspaceAndPinSection(pinned: Bool) async throws {
    let f = try await Fixture(); defer { f.remove() }
    let localA = try await f.db.createFolder(name: "Local A", location: f.location("A"))
    let remote = try await f.db.createFolder(name: "Remote", location: .init(
      workspaceID: "remote:other", rootPath: "/home/project", managed: false))
    let otherSection = try await f.db.createFolder(name: "Other pin section", location: f.location("Other"))
    let localB = try await f.db.createFolder(name: "Local B", location: f.location("B"))
    for id in [localA, remote, localB] {
      _ = try await f.db.setFolderPinned(id: id, isPinned: pinned)
    }
    _ = try await f.db.setFolderPinned(id: otherSection, isPinned: !pinned)
    let before = try await f.db.workspaceOverview().folders
    #expect(try await f.db.moveFolder(id: localB, direction: .up))
    let after = try await f.db.workspaceOverview().folders
    let localIDs = after.filter { $0.executionWorkspaceID == f.owner && $0.isPinned == pinned }
      .sorted { $0.position < $1.position }.map(\.id)
    #expect(localIDs == [localB, localA])
    for untouched in [remote, otherSection] {
      #expect(after.first { $0.id == untouched } == before.first { $0.id == untouched })
    }
    #expect(try await !f.db.moveFolder(id: remote, direction: .up))
    #expect(try await !f.db.moveFolder(id: remote, direction: .down))
    #expect(try await !f.db.moveFolder(id: localB, direction: .up))
    #expect(try await f.db.moveFolder(id: localB, direction: .down))
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "history.sqlite"))
    let restored = try await reopened.workspaceOverview().folders
      .filter { $0.executionWorkspaceID == f.owner && $0.isPinned == pinned }
      .sorted { $0.position < $1.position }.map(\.id)
    #expect(restored == [localA, localB])
  }

  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "workspace-execution-roots-" + UUID().uuidString)
    let db: WorkspaceDatabase
    let owner = "device:mac-one"
    init() async throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try await WorkspaceDatabase(url: root.appending(path: "history.sqlite"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func location(_ name: String) -> WorkspaceFolderLocation {
      .init(workspaceID: owner, rootPath: root.appending(path: name).path, managed: false)
    }
    func draft() async throws -> String {
      let id = try await db.createLocalACPSession(runtimeKind: .codex, title: "Draft", ownerDeviceID: UUID())
      try await db.saveSessionExecutionRoot(id: id, folderID: nil, location: location("Ungrouped"), defaultPath: location("Ungrouped").rootPath)
      return id
    }
  }

  @Test func renameAndReferencesPreserveOneOwningRootAcrossReopen() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let location = f.location("Initial directory")
    let folder = try await f.db.createFolder(name: "Initial directory", location: location)
    _ = try await f.db.renameFolder(id: folder, name: "Display title")
    try await f.db.setFolderReferences(id: folder, paths: ["/other/project", "/reference", "/reference"])
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "history.sqlite"))
    let record = try #require(try await reopened.workspaceOverview().folders.first)
    #expect(record.name == "Display title" && record.rootPath == location.rootPath)
    #expect(record.executionWorkspaceID == f.owner)
    #expect(record.referencePaths == ["/other/project", "/reference"])
    try await reopened.setFolderReferences(id: folder, paths: [])
    #expect(try await reopened.workspaceOverview().folders.first?.rootPath == location.rootPath)
    #expect(try await reopened.workspaceOverview().folders.first?.referencePaths.isEmpty == true)
    await #expect(throws: (any Error).self) { try await reopened.setFolderReferences(id: folder, paths: ["relative/path"]) }
  }

}
