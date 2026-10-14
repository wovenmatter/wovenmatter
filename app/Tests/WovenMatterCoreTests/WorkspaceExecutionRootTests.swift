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

  @Test func scratchReservationSurvivesRetriesRenamesAndFolderChanges() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let id = try await f.draft()
    let base = f.location("Ungrouped").rootPath
    let date = Date(timeIntervalSince1970: 1_790_294_400)
    let scratch = try await f.db.reserveSessionScratchDirectory(id: id, workspaceID: f.owner,
      workspaceRoot: base, firstMessage: "Convert these PNGs to WebP please!", date: date)
    #expect(scratch.rootPath.contains("/scratch/2026-09-25-convert-these-pngs-to-webp-"))
    #expect(!FileManager.default.fileExists(atPath: scratch.rootPath))
    try await f.db.bindSessionScratchDirectory(id: id)
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "history.sqlite"))
    let retry = try await reopened.reserveSessionScratchDirectory(id: id, workspaceID: f.owner,
      workspaceRoot: base, firstMessage: "A changed title or retry", date: date.addingTimeInterval(86400))
    #expect(retry == scratch)
    let folder = try await reopened.createFolder(name: "Project", location: f.location("Project"))
    #expect(try await reopened.moveConversation(id: id, toFolderID: folder))
    #expect(try await reopened.moveConversation(id: id, toFolderID: nil))
    #expect(try await reopened.sessionExecutionRoot(id: id)?.rootPath == scratch.rootPath)
    try await reopened.lockSessionFolder(id: id)
    try await reopened.bindSessionScratchDirectory(id: id)
    await #expect(throws: (any Error).self) {
      try await reopened.reserveSessionScratchDirectory(id: id, workspaceID: "remote:other", workspaceRoot: "/home", firstMessage: "retry")
    }
  }

  @Test func scratchNamesCannotCollideOrEscapeAndNamedProjectsKeepTheirRoot() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let first = "11111111-1111-4111-8111-111112345678", second = "22222222-2222-4222-8222-222212345678"
    let base = f.root.path
    let a = try await f.db.reserveSessionScratchDirectory(id: first, workspaceID: f.owner, workspaceRoot: base, firstMessage: "../../etc repeated title")
    let b = try await f.db.reserveSessionScratchDirectory(id: second, workspaceID: f.owner, workspaceRoot: base, firstMessage: "../../etc repeated title")
    #expect(a.rootPath != b.rootPath)
    #expect(URL(fileURLWithPath: a.rootPath).deletingLastPathComponent().path == base + "/scratch")
    let id = try await f.draft()
    let folder = try await f.db.createFolder(name: "Project", location: f.location("Project"))
    #expect(try await f.db.moveConversation(id: id, toFolderID: folder))
    _ = try await f.db.reserveSessionScratchDirectory(id: id, workspaceID: f.owner, workspaceRoot: f.location("Ungrouped").rootPath, firstMessage: "Hello")
    await #expect(throws: (any Error).self) { try await f.db.bindSessionScratchDirectory(id: id) }
    #expect(try await f.db.sessionExecutionRoot(id: id)?.rootPath == f.location("Project").rootPath)
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
