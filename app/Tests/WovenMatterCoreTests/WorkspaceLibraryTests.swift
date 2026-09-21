import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Library", .serialized)
struct WorkspaceLibraryTests {
  struct Fixture {
    let root: URL
    let db: WorkspaceDatabase
    init() throws {
      root = FileManager.default.temporaryDirectory.appending(path: "library-tests-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      try db.bindDeviceOwnership(ownerDeviceID: UUID())
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func session(_ name: String = "Research", _ kind: AgentRuntimeKind = .codex) throws -> String {
      try db.createLocalACPSession(runtimeKind: kind, title: name, ownerDeviceID: UUID())
    }
    func exchange(_ conversation: String, text: String, reply: String = "Done") throws -> LocalACPRunIdentifiers {
      let run = try db.beginLocalACPRun(conversationID: conversation, content: text)
      try db.replaceLocalACPAssistantMessage(runID: run.runID, content: reply)
      try db.completeLocalACPRun(runID: run.runID)
      try db.indexLibraryMessages()
      return run
    }
  }

  @Test("activation excludes existing messages and old imported history, including later rewrites")
  func forwardOnly() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session()
    let old = try f.exchange(chat, text: "https://before.example")
    try f.db.transaction {
      try f.db.executeUnlocked("DROP TRIGGER library_new_message")
      try f.db.executeUnlocked("DELETE FROM library_items; DELETE FROM library_messages")
    }
    // Simulate a database predating feature activation: migration never scans its messages.
    try f.db.migrateLibrary()
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE dashboard_messages SET content='https://old-rewritten.example' WHERE id=?", [old.assistantMessageID]) }
    try f.db.indexLibraryMessages()
    #expect(try f.db.libraryItems().isEmpty)
    try f.db.transaction {
      try f.db.toolsExecuteUnlocked("INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at) VALUES('imported',?,'assistant','https://old-import.example','2020-01-01T00:00:00Z')", [chat])
    }
    let fresh = try f.exchange(chat, text: "https://new.example")
    let rows = try f.db.libraryItems()
    #expect(rows.count == 1)
    #expect(rows.first?.messageID == fresh.userMessageID)
    let reopened = try WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    try reopened.indexLibraryMessages()
    #expect(try reopened.libraryItems() == rows)
  }

  @Test("each exchange retains provenance; combined filters and pagination stay distinct")
  func filtering() throws {
    let f = try Fixture(); defer { f.close() }
    let local = try f.session(), remote = try f.session("Remote", .claudeCode)
    let remoteID = UUID().uuidString.lowercased()
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", [remoteID, remote]) }
    try f.db.setLibraryLocation(conversationID: local, workspaceName: "Local workspace", root: f.root.path)
    try f.db.setLibraryLocation(conversationID: remote, workspaceName: "Server", root: "/home/.woven-matter")
    let first = try f.exchange(local, text: "https://same.example", reply: "[Report](https://example.com/report.pdf)")
    _ = try f.exchange(remote, text: "https://same.example", reply: "![Photo](https://example.com/photo.png)")
    #expect(try f.db.libraryItems().count == 4)
    var q = LibraryQuery(); q.workspaces = ["local", remoteID]; q.sender = .me
    #expect(try f.db.libraryItems(query: q).count == 2)
    q.harnesses = ["codex"]
    #expect(try f.db.libraryItems(query: q).map(\.messageID) == [first.userMessageID])
    q.workspaces = []
    #expect(try f.db.libraryItems(query: q).isEmpty)
    q = .init(); q.kind = .photo; q.sender = .agent; q.workspaces = [remoteID]
    #expect(try f.db.libraryItems(query: q).first?.workspaceName == "Server")
    q.agents = ["missing"]
    #expect(try f.db.libraryItems(query: q).isEmpty)
    let firstPage = try f.db.libraryItems(limit: 2), secondPage = try f.db.libraryItems(limit: 2, offset: 2)
    #expect(Set((firstPage + secondPage).map(\.id)).count == 4)
    q = .init(); q.since = Date().addingTimeInterval(60)
    #expect(try f.db.libraryItems(query: q).isEmpty)
    q = .init(); q.search = "Report"
    #expect(try f.db.libraryItems(query: q).count == 1)
    #expect(try f.db.libraryFacets().count == 2)
  }

  @Test("attachments appear only after send; notes stay out; streaming links wait until completion")
  func attachmentLifecycle() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session()
    let url = f.root.appending(path: "photo.png"); try Data([1,2,3]).write(to: url)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: url, mimeType: "image/png")
    #expect(try f.db.libraryItems().isEmpty)
    let run = try f.db.beginLocalACPRun(conversationID: chat, input: .init(text: "", attachments: [.file(draft),
      .reference(.init(kind: .note, resourceID: "note", titleSnapshot: "Note", contentSnapshot: "https://private-note.example", revisionSnapshot: "1"))]))
    try f.db.appendLocalACPAssistantChunk(runID: run.runID, chunk: "[Incomplete](https://stream.example")
    try f.db.indexLibraryMessages()
    #expect(try f.db.libraryItems().map(\.kind) == [.photo])
    try f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "[Complete](https://stream.example)")
    try f.db.completeLocalACPRun(runID: run.runID)
    try f.db.indexLibraryMessages()
    let rows = try f.db.libraryItems()
    #expect(rows.count == 2)
    #expect(rows.first(where: { $0.kind == .photo })?.contentHash == draft.contentHash)
    #expect(rows.allSatisfy { $0.source != "https://private-note.example" })
    let files = LibraryFileStore(supportDirectory: f.root)
    let file = try #require(rows.first(where: { $0.kind == .photo }))
    let opened = try files.url(for: file)
    #expect(opened.pathExtension == "png")
    #expect(try Data(contentsOf: opened) == Data([1,2,3]))
  }

  @Test("archive preserves items, deletion removes items and defeats a late transfer")
  func deletion() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session()
    _ = try f.exchange(chat, text: "https://keep.example", reply: "[File](./report.pdf)")
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [chat]) }
    #expect(try f.db.libraryItems().count == 2)
    let pending = try #require(f.db.pendingLibraryFiles().first)
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-21T00:00:00Z", chat]) }
    try f.db.finishLibraryFile(id: pending.id, hash: String(repeating: "a", count: 64), size: 3)
    #expect(try f.db.libraryItems().isEmpty)
    #expect(try f.db.retainedLibraryHashes().isEmpty)
    #expect(throws: WorkspaceToolError.self) { try f.db.librarySourceMessage(id: pending.id) }
  }

  @Test("retained remote handback opens offline and copies deduplicate by content")
  func remoteRetention() async throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session()
    let configuration = RemoteWorkspaceConfiguration(name: "Server", workspaceID: "test", hostName: "host.invalid")
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", [configuration.id.uuidString.lowercased(), chat]) }
    _ = try f.exchange(chat, text: "Make a report", reply: "[Report](./report.pdf)")
    let bytes = Data("PDF fixture".utf8)
    let service = LibraryService(database: f.db, supportDirectory: f.root, remoteFiles: .init(runner: { destination, command, input in
      #expect(destination == "host.invalid"); #expect(command.contains("wovenmatter-test")); #expect(input == nil)
      return bytes
    }))
    try await service.synchronize(locations: [.init(conversationID: chat, name: "Server", root: "/home/.woven-matter")], workspaces: [configuration])
    let item = try #require(f.db.libraryItems().first)
    #expect(item.storage == "retained")
    #expect(item.sizeBytes == Int64(bytes.count))
    let opened = try await service.openURL(id: item.id)
    #expect(try Data(contentsOf: opened) == bytes)
    try await service.synchronize(locations: [], workspaces: [])
    #expect(try await service.openURL(id: item.id) == opened)
    let store = LibraryFileStore(supportDirectory: f.root)
    #expect(try store.retain(bytes) == item.contentHash)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appending(path: "library-files").path).count == 1)
  }

  @Test("local retention confines reads and cleanup removes only unreferenced managed files")
  func localFiles() throws {
    let f = try Fixture(); defer { f.close() }
    let workspace = f.root.appending(path: "workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let file = workspace.appending(path: "report.pdf"); try Data("original".utf8).write(to: file)
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
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: blob.path)
    try files.cleanup(retained: [hash], visible: [hash]); #expect(FileManager.default.fileExists(atPath: blob.path))
    try files.cleanup(retained: [], visible: []); #expect(!FileManager.default.fileExists(atPath: blob.path))
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test("native OpenCode uploads and image responses retain the canonical exchange once")
  func openCodeAttachments() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.db.createLocalACPSession(runtimeKind: .opencode, title: "Native", ownerDeviceID: UUID(),
      openCodeAssociation: ("fixture", "native"))
    let file = f.root.appending(path: "report.txt"); try Data("report".utf8).write(to: file)
    let draft = try MessageAttachmentStore(supportDirectory: f.root).stage(fileURL: file, mimeType: "text/plain")
    try f.db.saveOpenCodeSubmission(conversationID: chat, id: "upload", payload: [:], status: "sending",
      visibleText: "Review", input: .init(text: "Review", attachments: [.file(draft)]))
    #expect(try f.db.libraryItems().isEmpty)
    let now = Date().timeIntervalSince1970 * 1000
    let time: OpenCodeValue = ["created": .number(now), "completed": .number(now)]
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.messages = [
      ["id": "upload", "type": "user", "time": time, "content": .array([["type": "text", "text": "Review"]]),
        "files": .array([["uri": .string(file.absoluteString), "name": "report.txt", "mime": "text/plain"]])],
      ["id": "response", "type": "assistant", "time": time, "content": .array([["type": "text", "text": "Here is the image"]]),
        "files": .array([["uri": "data:image/png;base64,AQID", "name": "image.png", "mime": "image/png"]])]
    ]
    try f.db.saveOpenCodeSnapshot(snapshot, conversationID: chat)
    try f.db.saveOpenCodeSnapshot(snapshot, conversationID: chat)
    try f.db.indexLibraryMessages()
    let items = try f.db.libraryItems()
    #expect(items.count == 2)
    #expect(items.first { $0.sender == .me }?.contentHash == draft.contentHash)
    let image = try #require(items.first { $0.sender == .agent })
    #expect(image.kind == .photo); #expect(image.storage == "retained")
    #expect(try Data(contentsOf: LibraryFileStore(supportDirectory: f.root).url(for: image)) == Data([1, 2, 3]))
  }

  @Test("native attachment save failures preserve messages and expose a useful Library status")
  func embeddedFailures() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session(), run = try f.exchange(chat, text: "Generate", reply: "Attached image")
    // A file in place of the storage directory simulates an unwritable destination.
    try Data().write(to: f.root.appending(path: "library-files"))
    try f.db.captureGatewayLibraryFiles(.object(["content": .array([.object([
      "type": .string("image"), "fileName": .string("image.png"),
      "source": .object(["media_type": .string("image/png"), "data": .string("AQID")])
    ])])]), messageID: run.assistantMessageID, conversationID: chat)
    let item = try #require(f.db.libraryItems().first)
    #expect(item.storage == "unsupported"); #expect(item.error != nil); #expect(item.contentHash == nil)
    #expect(try f.db.librarySourceMessage(id: item.id) == "Attached image")
    #expect(try f.db.pendingLibraryFiles().isEmpty)
  }

  @Test("unavailable remote files can retry; clearing and message deletion remove their items")
  func retryAndClear() async throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session()
    let remote = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "fixture", hostName: "host.invalid")
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", [remote.id.uuidString.lowercased(), chat]) }
    let run = try f.exchange(chat, text: "https://example.com", reply: "[File](./report.txt)")
    let service = LibraryService(database: f.db, supportDirectory: f.root, remoteFiles: .init(runner: { _, _, _ in Data("report".utf8) }))
    try await service.synchronize(locations: [], workspaces: [])
    let item = try #require(f.db.libraryItems().first { $0.sender == .agent })
    #expect(item.storage == "unavailable")
    try await service.retry(id: item.id)
    try await service.synchronize(locations: [], workspaces: [remote])
    #expect(try f.db.libraryItem(id: item.id)?.storage == "retained")
    try f.db.transaction { try f.db.toolsExecuteUnlocked("DELETE FROM dashboard_messages WHERE id=?", [run.userMessageID]) }
    #expect(try f.db.libraryItems().count == 1)
    try f.db.transaction { try f.db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET context_generation=context_generation+1 WHERE id=?", [chat]) }
    try f.db.indexLibraryMessages()
    #expect(try f.db.libraryItems().isEmpty)
    #expect(try f.db.retainedLibraryHashes().isEmpty)
  }

  @Test("URL discovery preserves citations and filenames, ignores code, and deduplicates within a message")
  func links() {
    let links = LibraryLinkDiscovery.links(in: """
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

  @Test("date ranges use local calendar days including daylight saving transitions")
  func dates() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-09T12:00:00Z"))
    #expect(LibraryDateRange.today.start(now: now, calendar: calendar) == calendar.startOfDay(for: now))
    #expect(LibraryDateRange.week.start(now: now, calendar: calendar) == calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
    #expect(LibraryDateRange.all.start(now: now, calendar: calendar) == nil)
  }

  @Test("Library access checks its own capability independently of history")
  func tools() throws {
    let f = try Fixture(); defer { f.close() }
    let chat = try f.session(); _ = try f.exchange(chat, text: "https://example.com")
    try f.db.applyInitialSessionTools(.init(enabled: [.library]), sessionID: chat)
    let result = try f.db.queryAgentLibrary(callerID: chat)
    #expect(result.objectValue?["items"]?.arrayValue?.count == 1)
    try f.db.setSessionTools(.init(enabled: []), sessionID: chat)
    #expect(throws: WorkspaceToolError.self) { try f.db.queryAgentLibrary(callerID: chat) }
  }
}
