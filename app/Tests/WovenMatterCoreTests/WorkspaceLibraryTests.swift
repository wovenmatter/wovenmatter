import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Library", .serialized)
struct WorkspaceLibraryTests {
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
      try await db.createLocalACPSession(runtimeKind: kind, title: name, ownerDeviceID: UUID())
    }
    func exchange(_ conversation: String, text: String, reply: String = "Done") async throws -> LocalACPRunIdentifiers {
      let run = try await db.beginLocalACPRun(conversationID: conversation, content: text)
      try await db.replaceLocalACPAssistantMessage(runID: run.runID, content: reply)
      try await db.completeLocalACPRun(runID: run.runID)
      try await db.indexLibraryMessages()
      return run
    }
  }

  @Test("activation excludes existing messages and old imported history, including later rewrites")
  func forwardOnly() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let old = try await f.exchange(chat, text: "https://before.example")
    try await f.db.write { connection in try connection.transaction {
      try connection.executeUnlocked("DROP TRIGGER library_new_message")
      try connection.executeUnlocked("DELETE FROM library_items; DELETE FROM library_messages")
     } }
    // Simulate a database predating feature activation: migration never scans its messages.
    try await f.db.write { try $0.migrateLibrary() }
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE dashboard_messages SET content='https://old-rewritten.example' WHERE id=?", [old.assistantMessageID])
     } }
    try await f.db.indexLibraryMessages()
    #expect(try await f.db.libraryItems().isEmpty)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at) VALUES('imported',?,'assistant','https://old-import.example','2020-01-01T00:00:00Z')",
        [chat])
     } }
    let fresh = try await f.exchange(chat, text: "https://new.example")
    let rows = try await f.db.libraryItems()
    #expect(rows.count == 1)
    #expect(rows.first?.messageID == fresh.userMessageID)
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    try await reopened.indexLibraryMessages()
    #expect(try await reopened.libraryItems() == rows)
  }

  @Test("each exchange retains provenance; combined filters and pagination stay distinct")
  func filtering() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let local = try await f.session()
    let remote = try await f.session("Remote", .claudeCode)
    let remoteID = UUID().uuidString.lowercased()
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", [remoteID, remote])
     } }
    try await f.db.setLibraryLocation(conversationID: local, workspaceName: "Local workspace", root: f.root.path)
    try await f.db.setLibraryLocation(conversationID: remote, workspaceName: "Server", root: "/home/.woven-matter")
    let first = try await f.exchange(local, text: "https://same.example", reply: "[Report](https://example.com/report.pdf)")
    _ = try await f.exchange(remote, text: "https://same.example", reply: "![Photo](https://example.com/photo.png)")
    #expect(try await f.db.libraryItems().count == 4)
    var q = LibraryQuery()
    q.workspaces = ["local", remoteID]
    q.sender = .me
    #expect(try await f.db.libraryItems(query: q).count == 2)
    q.harnesses = ["codex"]
    #expect(try await f.db.libraryItems(query: q).map(\.messageID) == [first.userMessageID])
    q.workspaces = []
    #expect(try await f.db.libraryItems(query: q).isEmpty)
    q = .init()
    q.kind = .photo
    q.sender = .agent
    q.workspaces = [remoteID]
    #expect(try await f.db.libraryItems(query: q).first?.workspaceName == "Server")
    q.agents = ["missing"]
    #expect(try await f.db.libraryItems(query: q).isEmpty)
    let firstPage = try await f.db.libraryItems(limit: 2)
    let secondPage = try await f.db.libraryItems(limit: 2, offset: 2)
    #expect(Set((firstPage + secondPage).map(\.id)).count == 4)
    q = .init()
    q.since = Date().addingTimeInterval(60)
    #expect(try await f.db.libraryItems(query: q).isEmpty)
    q = .init()
    q.search = "Report"
    #expect(try await f.db.libraryItems(query: q).count == 1)
    #expect(try await f.db.libraryFacets().count == 2)
  }

  @Test("attachments appear only after send; notes stay out; streaming links wait until completion")
  func attachmentLifecycle() async throws {
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
    try await f.db.appendLocalACPAssistantChunk(runID: run.runID, chunk: "[Incomplete](https://stream.example")
    try await f.db.indexLibraryMessages()
    #expect(try await f.db.libraryItems().map(\.kind) == [.photo])
    try await f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "[Complete](https://stream.example)")
    try await f.db.completeLocalACPRun(runID: run.runID)
    try await f.db.indexLibraryMessages()
    let rows = try await f.db.libraryItems()
    #expect(rows.count == 2)
    #expect(rows.first(where: { $0.kind == .photo })?.contentHash == draft.contentHash)
    #expect(rows.allSatisfy { $0.source != "https://private-note.example" })
    let files = LibraryFileStore(supportDirectory: f.root)
    let file = try #require(rows.first(where: { $0.kind == .photo }))
    let opened = try files.url(for: file)
    #expect(opened.pathExtension == "png")
    #expect(try Data(contentsOf: opened) == Data([1, 2, 3]))
  }

  @Test("draft attachments open through the Library file path before send or indexing")
  func draftAttachmentOpening() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let source = f.root.appending(path: "Report.docx")
    let bytes = Data("Attached document".utf8)
    try bytes.write(to: source)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(
      fileURL: source, mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    // Opening uses the staged bytes even if the source in Downloads changes or disappears.
    try FileManager.default.removeItem(at: source)
    let service = LibraryService(database: f.db)
    let opened = try await service.openAttachmentURL(
      contentHash: draft.contentHash, fileName: draft.fileName, mimeType: draft.mimeType)
    #expect(opened.lastPathComponent == "Report.docx")
    #expect(try Data(contentsOf: opened) == bytes)
    #expect(opened != draft.localURL)
    let permissions = try FileManager.default.attributesOfItem(atPath: opened.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o400)
    #expect(try await f.db.libraryItems().isEmpty)

    let chat = try await f.session()
    _ = try await f.db.beginLocalACPRun(conversationID: chat, input: .init(text: "", attachments: [.file(draft)]))
    try await f.db.indexLibraryMessages()
    let item = try await #require(f.db.libraryItems().first)
    #expect(try await service.openURL(id: item.id) == opened)
    #expect(try Data(contentsOf: draft.localURL) == bytes)
  }

  @Test("attachment opening validates content identities and preserves the backend write boundary")
  func attachmentOpeningBoundary() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let service = LibraryService(database: f.db)
    for hash in ["../../workspace.sqlite", String(repeating: "a", count: 63), String(repeating: "A", count: 64)] {
      await #expect(throws: AgentMessageAttachmentError.self) {
        try await service.openAttachmentURL(contentHash: hash, fileName: "file.txt", mimeType: "text/plain")
      }
    }
    await #expect(throws: AgentMessageAttachmentError.self) {
      try await service.openAttachmentURL(
        contentHash: String(repeating: "a", count: 64), fileName: "missing.txt", mimeType: "text/plain")
    }
    let source = f.root.appending(path: "Screenshot.png")
    try Data([1, 2, 3]).write(to: source)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: source, mimeType: "image/png")
    let reader = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"), readOnlyProjection: true)
    let projection = LibraryService(database: reader)
    await #expect(throws: WorkspaceDatabaseError.readOnlyProjection) {
      try await projection.openAttachmentURL(
        contentHash: draft.contentHash, fileName: draft.fileName, mimeType: draft.mimeType)
    }
    let opened = try await service.openAttachmentURL(
      contentHash: draft.contentHash, fileName: "../../Screenshot.png", mimeType: draft.mimeType)
    #expect(opened.lastPathComponent == "....Screenshot.png")
    #expect(opened.deletingLastPathComponent().lastPathComponent == draft.contentHash)
  }

  @Test("archive preserves items, trash hides items and defeats a late transfer")
  func deletion() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    _ = try await f.exchange(chat, text: "https://keep.example", reply: "[File](./report.pdf)")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [chat])
     } }
    #expect(try await f.db.libraryItems().count == 2)
    let pending = try await #require(f.db.pendingLibraryFiles().first)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-21T00:00:00Z", chat])
     } }
    try await f.db.finishLibraryFile(id: pending.id, hash: String(repeating: "a", count: 64), size: 3)
    #expect(try await f.db.libraryItems().isEmpty)
    #expect(try await f.db.retainedLibraryHashes().isEmpty)
    await #expect(throws: WorkspaceToolError.self) { try await f.db.librarySourceMessage(id: pending.id) }
  }

  @Test("retained remote handback opens offline and copies deduplicate by content")
  func remoteRetention() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let configuration = RemoteWorkspaceConfiguration(name: "Server", workspaceID: "test", hostName: "host.invalid")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?",
        [configuration.id.uuidString.lowercased(), chat])
     } }
    _ = try await f.exchange(chat, text: "Make a report", reply: "[Report](./report.pdf)")
    let bytes = Data("PDF fixture".utf8)
    let service = LibraryService(
      database: f.db,
      remoteFiles: .init(runner: { destination, command, input in
        #expect(destination == "host.invalid")
        #expect(command.contains("wovenmatter-test"))
        #expect(input == nil)
        return bytes
      }))
    try await service.synchronize(
      locations: [.init(conversationID: chat, name: "Server", root: "/home/.woven-matter")],
      remoteWorkspace: { _ in configuration })
    let item = try await #require(f.db.libraryItems().first)
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
  }

  @Test("local retention confines reads and cleanup removes only unreferenced managed files")
  func localFiles() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let workspace = f.root.appending(path: "workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let file = workspace.appending(path: "report.pdf")
    try Data("original".utf8).write(to: file)
    let files = LibraryFileStore(supportDirectory: f.root)
    let bytes = try files.readLocal(source: "report.pdf", root: workspace)
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
  }

  @Test("native OpenCode uploads and image responses retain the canonical exchange once")
  func openCodeAttachments() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.db.createLocalACPSession(
      runtimeKind: .opencode, title: "Native", ownerDeviceID: UUID(),
      openCodeAssociation: ("fixture", "native"))
    let file = f.root.appending(path: "report.txt")
    try Data("report".utf8).write(to: file)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: file, mimeType: "text/plain")
    try await f.db.saveOpenCodeSubmission(
      conversationID: chat, id: "upload", payload: [:], status: "sending",
      visibleText: "Review", input: .init(text: "Review", attachments: [.file(draft)]))
    #expect(try await f.db.libraryItems().isEmpty)
    let now = Date().timeIntervalSince1970 * 1000
    let time: OpenCodeValue = ["created": .number(now), "completed": .number(now)]
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.messages = [
      [
        "id": "upload", "type": "user", "time": time, "content": .array([["type": "text", "text": "Review"]]),
        "files": .array([["uri": .string(file.absoluteString), "name": "report.txt", "mime": "text/plain"]]),
      ],
      [
        "id": "response", "type": "assistant", "time": time,
        "content": .array([["type": "text", "text": "Here is the image"]]),
        "files": .array([["uri": "data:image/png;base64,AQID", "name": "image.png", "mime": "image/png"]]),
      ],
    ]
    try await f.db.saveOpenCodeSnapshot(snapshot, conversationID: chat)
    try await f.db.saveOpenCodeSnapshot(snapshot, conversationID: chat)
    try await f.db.indexLibraryMessages()
    let items = try await f.db.libraryItems()
    #expect(items.count == 2)
    #expect(items.first { $0.sender == .me }?.contentHash == draft.contentHash)
    let image = try #require(items.first { $0.sender == .agent })
    #expect(image.kind == .photo)
    #expect(image.storage == .retained)
    #expect(try Data(contentsOf: LibraryFileStore(supportDirectory: f.root).url(for: image)) == Data([1, 2, 3]))
  }

  @Test("native attachment save failures preserve messages and expose a useful Library status")
  func embeddedFailures() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let run = try await f.exchange(chat, text: "Generate", reply: "Attached image")
    // A file in place of the storage directory simulates an unwritable destination.
    try Data().write(to: f.root.appending(path: "library-files"))
    try await f.db.captureGatewayLibraryFiles(
      .object([
        "content": .array([
          .object([
            "type": .string("image"), "fileName": .string("image.png"),
            "source": .object(["media_type": .string("image/png"), "data": .string("AQID")]),
          ])
        ])
      ]), messageID: run.assistantMessageID, conversationID: chat)
    let item = try await #require(f.db.libraryItems().first)
    #expect(item.storage == .unsupported)
    #expect(item.error != nil)
    #expect(item.contentHash == nil)
    #expect(try await f.db.librarySourceMessage(id: item.id) == "Attached image")
    #expect(try await f.db.pendingLibraryFiles().isEmpty)
  }

  @Test("unavailable remote files can retry; clearing and message deletion remove their items")
  func retryAndClear() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let remote = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "fixture", hostName: "host.invalid")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?",
        [remote.id.uuidString.lowercased(), chat])
     } }
    let run = try await f.exchange(chat, text: "https://example.com", reply: "[File](./report.txt)")
    let service = LibraryService(database: f.db, remoteFiles: .init(runner: { _, _, _ in Data("report".utf8) }))
    try await service.synchronize(locations: [], remoteWorkspace: { _ in nil })
    let item = try await #require(f.db.libraryItems().first { $0.sender == .agent })
    #expect(item.storage == .unavailable)
    try await service.retry(id: item.id)
    try await service.synchronize(locations: [], remoteWorkspace: { _ in remote })
    #expect(try await f.db.libraryItem(id: item.id)?.storage == .retained)
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

  @Test("native attachment echoes reuse uploads and complete an already discovered file")
  func nativeReconciliation() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let url = f.root.appending(path: "image.png")
    try Data([1, 2, 3]).write(to: url)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: url, mimeType: "image/png")
    let run = try await f.db.beginLocalACPRun(conversationID: chat, input: .init(text: "Look", attachments: [.file(draft)]))
    let payload: GatewayJSONValue = .object([
      "content": .array([
        .object([
          "type": .string("image"), "url": .string("./image.png"), "fileName": .string("image.png"),
          "mimeType": .string("image/png"), "data": .string("AQID"),
        ])
      ])
    ])
    try await f.db.captureGatewayLibraryFiles(payload, messageID: run.userMessageID, conversationID: chat)
    try await f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "[Image](./image.png)")
    try await f.db.completeLocalACPRun(runID: run.runID)
    try await f.db.indexLibraryMessages()
    try await f.db.captureGatewayLibraryFiles(payload, messageID: run.assistantMessageID, conversationID: chat)
    let rows = try await f.db.libraryItems()
    #expect(rows.count == 2)
    #expect(rows.first { $0.sender == .me }?.storage == .attachment)
    let returned = try #require(rows.first { $0.sender == .agent })
    #expect(returned.storage == .retained)
    #expect(returned.contentHash == draft.contentHash)
    // A queued filesystem copy cannot overwrite a native attachment that won the race.
    try await f.db.finishLibraryFile(id: returned.id, hash: nil, error: "late read failed")
    #expect(try await f.db.libraryItem(id: returned.id)?.storage == .retained)
  }

  @Test("remote access is checked for each transfer and after a connection changes")
  func remoteRevocation() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let remote = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "fixture", hostName: "host.invalid")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?",
        [remote.id.uuidString.lowercased(), chat])
     } }
    _ = try await f.exchange(chat, text: "Generate", reply: "[One](./one.txt) [Two](./two.txt)")
    actor Access {
      var calls = 0
      func resolve(_ remote: RemoteWorkspaceConfiguration) -> RemoteWorkspaceConfiguration? {
        calls += 1
        return calls == 1 ? remote : nil
      }
    }
    let access = Access()
    let service = LibraryService(database: f.db, remoteFiles: .init(runner: { _, _, _ in Data("file".utf8) }))
    try await service.synchronize(locations: [], remoteWorkspace: { _ in await access.resolve(remote) })
    let rows = try await f.db.libraryItems()
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.storage == .unavailable && $0.contentHash == nil })
    #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "library-files").path))
  }

  @Test("Library uses the workspace's ownership scope for listing, opening and source access")
  func ownership() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    _ = try await f.exchange(chat, text: "https://private.example", reply: "[File](./report.pdf)")
    let item = try await #require(f.db.libraryItems().first)
    // Keep the workspace's inferred operator stable while this one chat changes owner.
    _ = try await f.db.createFolder(name: "Local work")
    _ = try await f.db.createFolder(name: "More local work")
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
    #expect(try await f.db.libraryItem(id: item.id) == nil)
    await #expect(throws: WorkspaceToolError.self) { try await f.db.librarySourceMessage(id: item.id) }
  }

  @Test("Library revisions ignore ordinary messages and follow item metadata changes")
  func catalogRevision() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    let initial = try await f.db.libraryRevision()
    _ = try await f.exchange(chat, text: "Hello", reply: "Hello again")
    #expect(try await f.db.libraryRevision() == initial)
    _ = try await f.exchange(chat, text: "https://example.com")
    let indexed = try await f.db.libraryRevision()
    #expect(indexed > initial)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET title='Changed' WHERE id=?", [chat])
     } }
    #expect(try await f.db.libraryRevision() > indexed)
    #expect(try await f.db.libraryPage(query: .init(), count: 100).items.first?.conversationTitle == "Changed")
    let renamed = try await f.db.libraryRevision()
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked(
        "UPDATE desktop_local_acp_sessions SET runtime_kind='pi' WHERE conversation_id=?", [chat])
     } }
    #expect(try await f.db.libraryRevision() > renamed)
    #expect(try await f.db.libraryPage(query: .init(), count: 100).items.first?.harness == "pi")
  }

  @Test("encoded file links and long Unicode titles open without losing extensions")
  func encodedFileNames() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let url = f.root.appending(path: "my report.txt")
    try Data("contents".utf8).write(to: url)
    let files = LibraryFileStore(supportDirectory: f.root)
    #expect(try files.readLocal(source: "./my%20report.txt#section", root: f.root) == Data("contents".utf8))
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

  @Test("URL discovery preserves citations and filenames, ignores code, and deduplicates within a message")
  func links() {
    let links = LibraryLinkDiscovery.links(
      in: """
        [Source](https://example.com/a_(b)) https://example.com/a_(b).
        [Report](<./my report.pdf>) ![Screenshot](./screen.png)
        [1]: https://example.org/paper
        MEDIA:/tmp/photo.jpg
        ```sh
        curl https://not-an-exchange.example
        ```
        """)
    #expect(links.count == 5)
    #expect(links.contains { $0.source == "./my report.pdf" && $0.kind == .file })
    #expect(links.filter { $0.kind == .photo }.count == 2)
    #expect(!links.contains { $0.source.contains("not-an-exchange") })
    #expect(LibraryLinkDiscovery.links(in: "[danger](javascript:alert(1))").isEmpty)
  }

  @Test("large repetitive messages retain unique links without quadratic rescanning")
  func repetitiveLinkDiscovery() {
    let repeated = String(repeating: "[Same](https://example.com/same) ", count: 10_000)
    let links = LibraryLinkDiscovery.links(in: repeated + "https://example.com/final")
    #expect(links.map(\.source) == ["https://example.com/same", "https://example.com/final"])
    let unfinishedLabels = String(repeating: "[", count: 100_000)
    #expect(LibraryLinkDiscovery.links(in: unfinishedLabels + " https://example.com/final").map(\.source)
      == ["https://example.com/final"])
    let punctuation = String(repeating: ")", count: 100_000)
    #expect(LibraryLinkDiscovery.links(in: "https://example.com/a_(b)" + punctuation).map(\.source)
      == ["https://example.com/a_(b)"])
    let distinct = (0..<500).map { "[Item](https://example.com/\($0))" }.joined(separator: " ")
    #expect(LibraryLinkDiscovery.links(in: distinct).count == LibraryLinkDiscovery.maximumItemsPerMessage)
  }

  @Test("date ranges use local calendar days including daylight saving transitions")
  func dates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-09T12:00:00Z"))
    #expect(LibraryDateRange.today.start(now: now, calendar: calendar) == calendar.startOfDay(for: now))
    #expect(
      LibraryDateRange.week.start(now: now, calendar: calendar)
        == calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
    #expect(LibraryDateRange.all.start(now: now, calendar: calendar) == nil)
  }

  @Test("Library access checks its own capability independently of history")
  func tools() async throws {
    let f = try await Fixture()
    defer { f.close() }
    let chat = try await f.session()
    _ = try await f.exchange(chat, text: "https://example.com")
    try await f.db.applyInitialSessionTools(.init(enabled: [.library]), sessionID: chat)
    let result = try await f.db.queryAgentLibrary(callerID: chat)
    #expect(result.objectValue?["items"]?.arrayValue?.count == 1)
    do {
      _ = try await f.db.queryAgentLibrary(callerID: chat, id: UUID().uuidString)
      Issue.record("Expected a missing library item to fail")
    } catch WorkspaceToolError.notFound(let message) {
      #expect(message == "Library item not found.")
    } catch {
      Issue.record("Expected not_found, received \(error)")
    }
    try await f.db.setSessionTools(.init(enabled: []), sessionID: chat)
    await #expect(throws: WorkspaceToolError.self) { try await f.db.queryAgentLibrary(callerID: chat) }
  }
}
