import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Library", .serialized)
struct WorkspaceLibraryTests {

  @Test("local retention confines reads and cleanup removes only unreferenced managed files")
  func localFiles() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let workspace = f.root.appending(path: "workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let file = workspace.appending(path: "my report.txt")
    try Data("original".utf8).write(to: file)
    let files = LibraryFileStore(supportDirectory: f.root)
    let bytes = try files.readLocal(source: "./my%20report.txt#section", root: workspace)
    #expect(bytes == Data("original".utf8))
    let hash = try files.retain(bytes)
    try Data("changed".utf8).write(to: file)
    #expect(try Data(contentsOf: f.root.appending(path: "library-files/" + hash)) == bytes)
    #expect(throws: (any Error).self) { try files.readLocal(source: "/etc/passwd", root: workspace) }
    let symlink = workspace.appending(path: "alias.pdf")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    #expect(throws: (any Error).self) { try files.readLocal(source: symlink.path, root: workspace) }
    let blob = f.root.appending(path: "library-files/" + hash)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: blob.path)
    try files.cleanup(retained: [hash], visible: [hash])
    #expect(FileManager.default.fileExists(atPath: blob.path))
    try files.cleanup(retained: [], visible: [])
    #expect(!FileManager.default.fileExists(atPath: blob.path))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(
      try RemoteLibraryFiles.path(source: "./my%20report.txt#section", root: "/home/work")
        == "/home/work/./my report.txt")
    #expect(LibraryFileReference.path("file://other-host/report.txt") == nil)
    #expect(LibraryFileReference.path("./bad%00path.txt") == nil)
    let chat = try await f.session()
    let run = try await f.exchange(chat, text: "Generate")
    try await f.db.recordLibraryOutput(
      runID: run.runID,
      asset: .init(
        source: "", title: String(repeating: "文", count: 180),
        kind: .file, mimeType: "text/plain", data: Data("contents".utf8)))
    let item = try await #require(f.db.libraryItems().first)
    let opened = try files.url(for: item)
    #expect(opened.lastPathComponent.utf8.count <= 240)
    #expect(opened.pathExtension == "txt")
    #expect(try Data(contentsOf: opened) == Data("contents".utf8))
  }


  struct Fixture {
    let root: URL
    let db: WorkspaceDatabase
    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "library-tests-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      try await db.bindDeviceOwnership(ownerDeviceID: UUID())
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func session(_ name: String = "Research", _ kind: AgentRuntimeKind = .codex) async throws -> String {
      try await db.createFixtureLocalACPSession(runtimeKind: kind, title: name, ownerDeviceID: UUID())
    }
    func exchange(_ conversation: String, text: String, reply: String = "Done") async throws -> LocalACPRunIdentifiers {
      let run = try await db.beginLocalACPRun(conversationID: conversation, content: text)
      try await db.replaceLocalACPAssistantMessage(runID: run.runID, content: reply)
      try await db.completeLocalACPRun(runID: run.runID)
      try await db.indexLibraryMessages()
      return run
    }
  }

  @Test("sent attachments reconcile native echoes and remain scoped to their owning workspace")
  func attachmentLifecycleReconcilesNativeEchoesAndEnforcesOwnership() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let url = f.root.appending(path: "photo.png")
    try Data([1, 2, 3]).write(to: url)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: url, mimeType: "image/png")
    #expect(try await f.db.libraryItems().isEmpty)
    let run = try await f.db.beginLocalACPRun(
      conversationID: chat,
      input: .init(
        text: "",
        attachments: [
          .file(draft),
          .reference(
            .init(
              kind: .note, resourceID: "note", titleSnapshot: "Note", contentSnapshot: "https://private-note.example",
              revisionSnapshot: "1")),
        ]))
    let payload: GatewayJSONValue = .object([
      "content": .array([
        .object([
          "type": .string("image"), "url": .string("./photo.png"), "fileName": .string("photo.png"),
          "mimeType": .string("image/png"), "data": .string("AQID"),
        ])
      ])
    ])
    try await f.db.captureGatewayLibraryFiles(payload, messageID: run.userMessageID, conversationID: chat)
    try await f.db.appendLocalACPAssistantChunk(runID: run.runID, chunk: "[Incomplete](https://stream.example")
    try await f.db.indexLibraryMessages()
    #expect(try await f.db.libraryItems().map(\.kind) == [.photo])
    try await f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "[Complete](https://stream.example) [Image](./photo.png)")
    try await f.db.completeLocalACPRun(runID: run.runID)
    try await f.db.indexLibraryMessages()
    try await f.db.captureGatewayLibraryFiles(payload, messageID: run.assistantMessageID, conversationID: chat)
    let rows = try await f.db.libraryItems()
    #expect(rows.count == 3)
    #expect(rows.filter { $0.sender == .me && $0.kind == .photo }.count == 1)
    #expect(rows.filter { $0.sender == .agent && $0.kind == .photo }.count == 1)
    #expect(rows.filter { $0.source == "https://stream.example" }.count == 1)
    #expect(rows.first(where: { $0.kind == .photo })?.contentHash == draft.contentHash)
    #expect(rows.allSatisfy { $0.source != "https://private-note.example" })
    #expect(rows.first { $0.sender == .me }?.storage == .attachment)
    let returned = try #require(rows.first { $0.sender == .agent && $0.kind == .photo })
    #expect(returned.storage == .retained)
    #expect(returned.contentHash == draft.contentHash)
    try await f.db.finishLibraryFile(id: returned.id, hash: nil, error: "late read failed")
    #expect(try await f.db.libraryItem(id: returned.id)?.storage == .retained)
    let files = LibraryFileStore(supportDirectory: f.root)
    let file = try #require(rows.first(where: { $0.kind == .photo }))
    let opened = try files.url(for: file)
    #expect(opened.pathExtension == "png")
    #expect(try Data(contentsOf: opened) == Data([1, 2, 3]))
      // Keep the workspace's inferred operator stable while this one chat changes owner.
    _ = try await f.db.createFixtureFolder(name: "Local work")
    _ = try await f.db.createFixtureFolder(name: "More local work")
    let visibleRevision = try await f.db.libraryRevision()
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE dashboard_conversations SET desktop_owned=0,user_id='different-operator' WHERE id=?", [chat])
     } }
    #expect(try await f.db.libraryRevision() > visibleRevision)
    #expect(try await f.db.libraryItems().isEmpty)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE dashboard_conversations SET desktop_owned=1,governing_plane='platform' WHERE id=?", [chat])
     } }
    #expect(try await f.db.libraryItems().isEmpty)
    #expect(try await f.db.libraryFacets().isEmpty)
    #expect(try await f.db.pendingLibraryFiles().isEmpty)
    #expect(try await f.db.libraryItem(id: file.id) == nil)
    await #expect(throws: WorkspaceToolError.self) { try await f.db.librarySourceMessage(id: file.id) }
  }

  @Test("a synchronization requested during another pass runs after it rather than being dropped")
  func concurrentSynchronizationIsSerialized() async throws {
    let f = try await Fixture()
    defer { f.close() }
    // The first pass suspends while resolving a remote workspace.
    let remoteChat = try await f.session("Remote")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", [UUID().uuidString.lowercased(), remoteChat])
    } }
    _ = try await f.exchange(remoteChat, text: "Report", reply: "[Report](./report.pdf)")
    let gate = LibraryPassGate()
    let service = LibraryService(database: f.db)
    let first = Task { try await service.synchronize(locations: [], remoteWorkspace: { _ in await gate.hold(); return nil }) }
    try await gate.untilHeld()
    // A local file arrives after the first pass indexed its messages.
    let directory = f.root.appending(path: "local-workspace")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bytes = Data("Category,Amount".utf8)
    try bytes.write(to: directory.appending(path: "budget.csv"))
    let localChat = try await f.session("Local")
    let run = try await f.exchange(localChat, text: "Budget", reply: "[Budget](./budget.csv)")
    let returned = LibraryPassGate()
    let second = Task {
      try await service.synchronize(locations: [.init(conversationID: localChat, name: "Local", root: directory.path)],
        remoteWorkspace: { _ in nil })
      await returned.hold(waiting: false)
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await !returned.held, "A concurrent request must wait for its own pass")
    await gate.release()
    try await first.value; try await second.value
    let id = WorkspaceLibraryItem.identifier(messageID: run.assistantMessageID, source: "./budget.csv")
    let item = try #require(try await f.db.libraryItem(id: id))
    #expect(item.storage == .retained && item.sizeBytes == Int64(bytes.count))
  }

  @Test("retained remote handback opens offline and copies deduplicate by content")
  func remoteRetention() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let configuration = RemoteWorkspaceConfiguration(name: "Server", workspaceID: "test", hostName: "host.invalid",
      kind: .host, dataRoot: "/srv/wovenmatter-test", workspaceRoot: "/srv/wovenmatter-test/workspace")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?",
        [configuration.id.uuidString.lowercased(), chat])
     } }
    let run = try await f.exchange(chat, text: "https://example.com", reply: "[Report](./report.pdf)")
    let bytes = Data("PDF fixture".utf8)
    let service = LibraryService(
      database: f.db,
      remoteFiles: .init(runner: { destination, command, input in
        #expect(destination == "host.invalid")
        #expect(command.contains("/srv/wovenmatter-test/current/bin/wm-exec"))
        #expect(!command.contains("docker exec"))
        #expect(input == nil)
        return bytes
      }))
    try await service.synchronize(locations: [], remoteWorkspace: { _ in nil })
    let unavailable = try await #require(f.db.libraryItems().first { $0.sender == .agent })
    #expect(unavailable.storage == .unavailable)
    try await service.retry(id: unavailable.id)
    try await service.synchronize(
      locations: [.init(conversationID: chat, name: "Server", root: "/srv/wovenmatter-test/workspace")],
      remoteWorkspace: { _ in configuration })
    let item = try await #require(f.db.libraryItems().first { $0.sender == .agent })
    #expect(item.storage == .retained)
    #expect(item.sizeBytes == Int64(bytes.count))
    let opened = try await service.openURL(id: item.id)
    #expect(try Data(contentsOf: opened) == bytes)
    try await service.synchronize(locations: [], remoteWorkspace: { _ in nil })
    #expect(try await service.openURL(id: item.id) == opened)
    let store = LibraryFileStore(supportDirectory: f.root)
    #expect(try store.retain(bytes) == item.contentHash)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: f.root.appending(path: "library-files").path).count == 1)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("DELETE FROM dashboard_messages WHERE id=?", [run.userMessageID])
     } }
    #expect(try await f.db.libraryItems().count == 1)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE dashboard_conversations SET context_generation=context_generation+1 WHERE id=?", [chat])
     } }
    try await f.db.indexLibraryMessages()
    #expect(try await f.db.libraryItems().isEmpty)
    #expect(try await f.db.retainedLibraryHashes().isEmpty)
  }

}

private actor LibraryPassGate {
  private(set) var held = false
  private var continuation: CheckedContinuation<Void, Never>?
  func hold(waiting: Bool = true) async {
    held = true
    if waiting { await withCheckedContinuation { continuation = $0 } }
  }
  func release() { continuation?.resume(); continuation = nil }
  func untilHeld() async throws {
    for _ in 0..<2_000 where !held { try await Task.sleep(for: .milliseconds(5)) }
    #expect(held)
  }
}
