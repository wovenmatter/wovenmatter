import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Execution workspace roots")
struct WorkspaceExecutionRootTests {
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

  @Test func draftMovesWithinItsWorkspaceAndLocksAfterFirstMessage() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let first = try await f.db.createFolder(name: "First", location: f.location("First"))
    let second = try await f.db.createFolder(name: "Second", location: f.location("Second"))
    let foreign = try await f.db.createFolder(name: "Remote", location: .init(workspaceID: "remote:other", rootPath: "/home/project", managed: true))
    let id = try await f.draft()
    #expect(try await f.db.moveConversation(id: id, toFolderID: first))
    #expect(try await f.db.sessionExecutionRoot(id: id)?.rootPath == f.location("First").rootPath)
    await #expect(throws: (any Error).self) { try await f.db.moveConversation(id: id, toFolderID: foreign) }
    #expect(try await f.db.moveConversation(id: id, toFolderID: second))
    #expect(try await f.db.moveConversation(id: id, toFolderID: nil))
    #expect(try await f.db.sessionExecutionRoot(id: id)?.rootPath == f.location("Ungrouped").rootPath)
    #expect(try await f.db.moveConversation(id: id, toFolderID: first))
    try await f.db.lockSessionFolder(id: id)
    let run = try await f.db.beginLocalACPRun(conversationID: id, content: "First message")
    try await f.db.completeLocalACPRun(runID: run.runID)
    await #expect(throws: (any Error).self) { try await f.db.moveConversation(id: id, toFolderID: second) }
    await #expect(throws: (any Error).self) { try await f.db.moveConversation(id: id, toFolderID: nil) }
    _ = try await f.db.deleteFolder(id: first)
    #expect(try await f.db.sessionExecutionRoot(id: id)?.rootPath == f.location("First").rootPath)
    #expect(try await f.db.conversationContent(id: id).messages.first?.content == "First message")
  }

  @Test func reusedScheduledSessionKeepsCapturedRootAfterFolderRemoval() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let location = f.location("Scheduled project")
    let folder = try await f.db.createFolder(name: "Scheduled", location: location)
    let id = try await f.db.createLocalACPSession(runtimeKind: .codex, title: "Scheduled", ownerDeviceID: UUID())
    try await f.db.saveSessionExecutionRoot(id: id, folderID: folder, location: location, defaultPath: f.location("Ungrouped").rootPath)
    try await f.db.lockSessionFolder(id: id)
    _ = try await f.db.deleteFolder(id: folder)
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "history.sqlite"))
    try await reopened.saveSessionExecutionRoot(id: id, folderID: folder, location: location, defaultPath: f.location("Ungrouped").rootPath)
    #expect(try await reopened.sessionExecutionRoot(id: id)?.rootPath == location.rootPath)
    #expect(try await reopened.workspaceOverview().conversations.first(where: { $0.id == id })?.folderID == folder)
    await #expect(throws: (any Error).self) {
      try await reopened.saveSessionExecutionRoot(id: id, folderID: folder,
        location: .init(workspaceID: "remote:other", rootPath: location.rootPath, managed: false), defaultPath: location.rootPath)
    }
    await #expect(throws: (any Error).self) {
      try await reopened.saveSessionExecutionRoot(id: id, folderID: folder, location: f.location("Different"), defaultPath: location.rootPath)
    }
  }

  @Test func rootsCannotBeReassignedAndOldSessionsRemainReadable() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let id = try await f.draft()
    let managedID = try await f.db.createLocalACPSession(runtimeKind: .codex, title: "Managed draft", ownerDeviceID: UUID())
    let managed = WorkspaceFolderLocation(workspaceID: f.owner, rootPath: f.root.appending(path: "Managed").path, managed: true)
    for _ in 0..<2 {
      try await f.db.saveSessionExecutionRoot(id: managedID, folderID: nil, location: managed, defaultPath: f.location("Ungrouped").rootPath)
    }
    #expect(try await f.db.sessionExecutionRoot(id: managedID)?.rootPath == managed.rootPath)
    await #expect(throws: (any Error).self) {
      try await f.db.saveSessionExecutionRoot(id: id, folderID: nil, location: f.location("Changed"), defaultPath: f.location("Ungrouped").rootPath)
    }
    let old = try await f.db.createLocalACPSession(runtimeKind: .codex, title: "Retained old chat", ownerDeviceID: UUID())
    #expect(try await f.db.sessionExecutionRoot(id: old) == nil)
    await #expect(throws: (any Error).self) { try await f.db.lockSessionFolder(id: old) }
    #expect(try await f.db.conversationContent(id: old).messages.isEmpty)
    #expect(try await f.db.workspaceOverview().conversations.contains(where: { $0.id == old }))
  }
}
