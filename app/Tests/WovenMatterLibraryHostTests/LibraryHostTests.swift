#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Testing
@testable import WovenMatterCompanion
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterLibraryHost

/// A one-request HTTP/1.1 client; the host closes every connection after its response.
private struct HTTPReply { let status: Int; let headers: [String: String]; let body: Data
  var json: GatewayJSONValue? { try? JSONDecoder().decode(GatewayJSONValue.self, from: body) }
}

private func send(_ method: String, _ path: String, unix: String? = nil, port: UInt16? = nil,
                  headers: [String: String] = [:], body: Data = Data()) throws -> HTTPReply {
  let fd: Int32
  if let unix {
    fd = socket(AF_UNIX, PortablePOSIX.streamSocket, 0)
    var address = try #require(PortablePOSIX.unixAddress(path: unix))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(result == 0)
  } else {
    fd = socket(AF_INET, PortablePOSIX.streamSocket, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = try #require(port).bigEndian
    address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(result == 0)
  }
  defer { Darwin.close(fd) }
  var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
  var all = headers
  if method == "POST" { all["Content-Type"] = "application/json"; all["Content-Length"] = String(body.count) }
  for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
  var wire = Data((head + "\r\n").utf8); wire.append(body)
  var offset = 0
  while offset < wire.count {
    let written = wire.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), wire.count - offset) }
    try #require(written > 0); offset += written
  }
  var response = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
  while true {
    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if count <= 0 { break }
    response.append(contentsOf: buffer[0..<count])
  }
  let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
  let lines = String(decoding: response[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
  let status = Int(lines[0].split(separator: " ")[1]) ?? 0
  var parsed: [String: String] = [:]
  for line in lines.dropFirst() { if let colon = line.firstIndex(of: ":") {
    parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
  } }
  return HTTPReply(status: status, headers: parsed, body: Data(response[separator.upperBound...]))
}

private final class HostFixture {
  let directory: URL
  let host: LibraryHost
  let port: UInt16
  let socket: String
  let token: String

  init(transport: LibraryPeerTransport = .urlSession(), endpoint: URL? = nil) async throws {
    // Short path: Unix socket paths are limited to about 100 bytes.
    directory = URL(fileURLWithPath: "/tmp").appending(path: "wml-\(UUID().uuidString.prefix(8))")
    let layout = LibraryHostLayout(root: directory)
    host = try await LibraryHost(layout: layout, endpoints: endpoint.map { [$0] } ?? [], transport: transport)
    socket = layout.defaultSocket.path
    port = try host.listen(port: 0, socket: layout.defaultSocket)
    token = try String(contentsOf: layout.defaultTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func mcp(_ caller: String, groups: String = "notes,history,calendar,library", _ method: String,
           _ params: [String: GatewayJSONValue] = [:]) throws -> GatewayJSONValue {
    let message: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": .object(params)])
    let reply = try send("POST", "/v1/mcp", unix: socket, headers: [
      "Authorization": "Bearer " + token, "X-Woven-Conversation-ID": caller, "X-Woven-Enabled-Groups": groups,
      "MCP-Protocol-Version": "2025-06-18"], body: try JSONEncoder().encode(message))
    #expect(reply.status == 200)
    return try #require(reply.json)
  }

  struct ToolResult { let success: Bool; let value: [String: GatewayJSONValue]; let error: String? }

  /// Calls a tool; its structured content is the WovenMatterToolResponse.
  func call(_ caller: String, _ name: String, _ arguments: [String: GatewayJSONValue]) throws -> ToolResult {
    let reply = try mcp(caller, "tools/call", ["name": .string(name), "arguments": .object(arguments)])
    let response = try #require(reply.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue, "\(reply)")
    return ToolResult(success: response["success"] == .bool(true), value: response["result"]?.objectValue ?? [:],
                      error: response["error"]?.stringValue)
  }

  func storedContent(_ noteID: String) throws -> String {
    var handle: OpaquePointer?
    try #require(sqlite3_open_v2(directory.appending(path: "library/workspace.sqlite").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(handle, "SELECT content FROM notes WHERE id=?", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, noteID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    try #require(sqlite3_step(statement) == SQLITE_ROW)
    return String(cString: try #require(sqlite3_column_text(statement, 0)))
  }

  func remove() { host.stop(); try? FileManager.default.removeItem(at: directory) }
}

@Suite("wovenmatter-library host", .serialized)
struct LibraryHostTests {
  @Test func optionsRequireAnExplicitDataRoot() throws {
    #expect(throws: LibraryHostError.self) { try LibraryHostOptions.parse([]) }
    #expect(try LibraryHostOptions.parse(["--version"]) == nil)
    let options = try #require(try LibraryHostOptions.parse(["--data-root", "/srv/woven", "--port", "4100", "--socket", "/run/x.sock",
                                                             "--harness-catalog", "/opt/release/harnesses/catalog.json", "--migrate-only"]))
    #expect(options.dataRoot.path == "/srv/woven" && options.port == 4100 && options.socket?.path == "/run/x.sock" && options.migrateOnly)
    #expect(options.harnessCatalog?.path == "/opt/release/harnesses/catalog.json")
    #expect(throws: LibraryHostError.self) { try LibraryHostOptions.parse(["--data-root", "/a", "--port", "70000"]) }
    #expect(throws: LibraryHostError.self) { try LibraryHostOptions.parse(["--data-root", "/a", "--bogus"]) }
  }

  @Test func tokenFilesArePrivateAndReused() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "run/token")
    let token = try LibraryHostToken.load(file)
    let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(token.accepts(value) && !token.accepts(value + "x") && !token.accepts(nil))
    #expect(try LibraryHostToken.load(file, create: false).accepts(value))
    var info = stat(); #expect(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(chmod(file.path, 0o644) == 0)
    #expect(throws: LibraryHostError.self) { try LibraryHostToken.load(file) }
  }

  @Test func healthAndMountsOnLoopbackAndTokenOnTheSocket() async throws {
    let fixture = try await HostFixture(); defer { fixture.remove() }
    let health = try send("GET", "/v1/health", port: fixture.port)
    #expect(health.status == 200 && health.json?.objectValue?["status"]?.stringValue == "ok")
    #expect(try send("GET", "/wovenmatter/v1/health", port: fixture.port).status == 200)
    #expect(try send("GET", "/wovenmatter/v1/peers/challenge", port: fixture.port).status == 404)
    fixture.host.mount(prefix: "/v1/peers/") { request in .init(status: 200, body: Data(request.target.utf8)) }
    let mounted = try send("GET", "/wovenmatter/v1/peers/challenge", port: fixture.port)
    #expect(mounted.status == 200 && String(decoding: mounted.body, as: UTF8.self) == "/wovenmatter/v1/peers/challenge")
    // The local API is not on the network listener, and requires the token.
    #expect(try send("POST", "/v1/mcp", port: fixture.port, body: Data("{}".utf8)).status == 404)
    #expect(try send("GET", "/v1/health", unix: fixture.socket).status == 401)
    #expect(try send("GET", "/v1/health", unix: fixture.socket, headers: ["Authorization": "Bearer wrong"]).status == 401)
    #expect(try send("GET", "/v1/health", unix: fixture.socket, headers: ["Authorization": "Bearer " + fixture.token]).status == 200)
    var info = stat(); #expect(lstat(fixture.socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
  }

  @Test func libraryToolsServeOnlyLibraryGroups() async throws {
    let fixture = try await HostFixture(); defer { fixture.remove() }
    let caller = UUID().uuidString.lowercased()
    let listed = try fixture.mcp(caller, groups: "notes,history,calendar,library,html,sessions,browser", "tools/list")
    let names = Set(try #require(listed.objectValue?["result"]?.objectValue?["tools"]?.arrayValue).compactMap { $0.objectValue?["name"]?.stringValue })
    #expect(names.contains("woven_notes_read") && names.contains("woven_calendar_list") && names.contains("woven_history_search"))
    #expect(names.contains("woven_library_list") && names.contains("woven_notes_create"))
    #expect(!names.contains("woven_sessions_list") && !names.contains("woven_browser_use") && !names.contains("woven_html_render"))
    let denied = try fixture.mcp(caller, "tools/call", ["name": .string("woven_sessions_list"), "arguments": .object([:])])
    #expect(denied.objectValue?["error"] != nil)
    for name in ["woven_calendar_list", "woven_history_conversations", "woven_library_list", "woven_notes_list"] {
      let result = try fixture.call(caller, name, [:])
      #expect(result.success, "\(name): \(result.error ?? "")")
    }
    let sheet = try fixture.call(caller, "woven_notes_create", ["title": .string("Sheet"), "kind": .string("spreadsheet")])
    #expect(sheet.success, "\(sheet.error ?? "")")
    // A caller without the group is refused by the shared executor's policy check.
    let narrowed = try fixture.mcp(caller, groups: "history", "tools/call", ["name": .string("woven_notes_list"), "arguments": .object([:])])
    #expect(narrowed.objectValue?["error"] != nil)
  }

  /// Creates, reads and edits a note through the socket API and checks the
  /// stored document equals the direct NoteDocument edit, byte for byte.
  /// With WOVENMATTER_NOTE_PARITY_OUT set, the inputs and stored bytes are
  /// written there so another platform can replay them (see the next test).
  @Test func noteEditsThroughTheSocketMatchDirectDocumentEdits() async throws {
    let fixture = try await HostFixture(); defer { fixture.remove() }
    let caller = UUID().uuidString.lowercased()
    let created = try fixture.call(caller, "woven_notes_create", ["title": .string("Parity")])
    let noteID = try #require(created.value["id"]?.stringValue, "\(created.error ?? "")")
    let first = try fixture.call(caller, "woven_notes_read", ["noteID": .string(noteID)])
    let initial = try #require(first.value["content"]?.stringValue)
    #expect(try fixture.storedContent(noteID) == initial)
    let document = try NoteDocument.editableDocument(from: initial)
    let blockID = try #require(document.blocks.first?.id)
    var revision = try #require(first.value["revision"]?.stringValue)

    let block = NoteBlock.richText(.init(id: blockID, style: .heading1, runs: [
      .init(text: "Grüße / \"quoted\" ✓ 😀 tab\there", bold: true),
      .init(text: " and a link", fontSize: 13.5, italic: true, link: "https://example.com/a?b=c&d=e")
    ], list: .init(levels: [.init(id: "list-1", markerFormat: "{decimal}.")], headIndent: 36.5, firstLineHeadIndent: 18.25)))
    let operations: [NoteEditOperation] = [.replaceBlock(id: blockID, block: block), .setTitle("Paritý 1/2"),
                                           .setParagraphStyle(blockID: blockID, style: .heading2)]
    let blockJSON = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(block))
    for (name, arguments) in [
      ("woven_notes_replace_block", ["id": GatewayJSONValue.string(blockID), "block": blockJSON]),
      ("woven_notes_set_title", ["title": .string("Paritý 1/2")]),
      ("woven_notes_format", ["blockID": .string(blockID), "style": .string("heading2")])
    ] {
      var input = arguments; input["noteID"] = .string(noteID); input["revision"] = .string(revision)
      let result = try fixture.call(caller, name, input)
      #expect(result.success, "\(name): \(result.error ?? "")")
      revision = try #require(result.value["revision"]?.stringValue)
    }
    let stored = try fixture.storedContent(noteID)
    var expected = document
    _ = try expected.apply(operations)
    #expect(try expected.encoded() == stored)
    let read = try fixture.call(caller, "woven_notes_read", ["noteID": .string(noteID)])
    #expect(read.value["content"]?.stringValue == stored)

    // A random-ID edit still succeeds through the same path.
    let appended = try fixture.call(caller, "woven_notes_append", ["noteID": .string(noteID), "text": .string("tail"), "revision": .string(revision)])
    #expect(appended.success, "\(appended.error ?? "")")
    #expect(try fixture.storedContent(noteID).contains("tail"))

    if let output = ProcessInfo.processInfo.environment["WOVENMATTER_NOTE_PARITY_OUT"] {
      let url = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(initial.utf8).write(to: url.appending(path: "initial.json"))
      try JSONEncoder().encode(operations).write(to: url.appending(path: "operations.json"))
      try Data(stored.utf8).write(to: url.appending(path: "stored.json"))
    }
  }

  /// Replays another platform's parity fixture with this platform's code.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_NOTE_PARITY_IN"] != nil))
  func replayedNoteEditsMatchAnotherPlatformByteForByte() throws {
    let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WOVENMATTER_NOTE_PARITY_IN"]))
    var document = try NoteDocument.editableDocument(from: String(decoding: try Data(contentsOf: url.appending(path: "initial.json")), as: UTF8.self))
    let operations = try JSONDecoder().decode([NoteEditOperation].self, from: Data(contentsOf: url.appending(path: "operations.json")))
    _ = try document.apply(operations)
    let stored = try Data(contentsOf: url.appending(path: "stored.json"))
    #expect(Data(try document.encoded().utf8) == stored)
  }

  /// A Mac reads the host's identity, signs its entry and hands it the
  /// records over the socket; a phone that Mac added then uses the mobile
  /// API with signed requests until a Mac removes it.
  @Test func membersAdoptionAndSignedMobileRequests() async throws {
    let fixture = try await HostFixture(); defer { fixture.remove() }
    let auth = ["Authorization": "Bearer " + fixture.token]
    let identity = try JSONDecoder().decode(LibraryHost.Identity.self, from: send("GET", "/wovenmatter/v1/identity", port: fixture.port).body)
    #expect(identity.kind == .linux && identity.publicKey.count == 32)
    #expect(try send("GET", "/v1/health", port: fixture.port).json?.objectValue?["deviceID"]?.stringValue == identity.deviceID)
    #expect(try JSONDecoder().decode(LibraryHost.Identity.self, from: send("GET", "/v1/identity", unix: fixture.socket, headers: auth).body) == identity)

    let macRoot = fixture.directory.appending(path: "mac")
    try FileManager.default.createDirectory(at: macRoot, withIntermediateDirectories: true)
    let macDatabase = try await WorkspaceDatabase(url: macRoot.appending(path: "workspace.sqlite"))
    let mac = MemberDirectory(database: macDatabase, identity: try MemberIdentity.loadOrCreate(file: macRoot.appending(path: "mac.key"),
      deviceID: try await macDatabase.companionLibraryIdentity().hostDeviceID, kind: .mac), cacheLifetime: 0)
    try await mac.ensureSelf(name: "Studio Mac", endpoints: [URL(string: "https://studio.tailnet.ts.net/")!])
    try await mac.add(deviceID: identity.deviceID, kind: .linux, name: "Box", publicKey: identity.publicKey,
                      endpoints: [URL(string: "https://box.tailnet.ts.net/wovenmatter/")!])
    let phone = try MemberIdentity.loadOrCreate(file: macRoot.appending(path: "phone.key"), deviceID: UUID().uuidString.lowercased(), kind: .ios)
    try await mac.add(deviceID: phone.deviceID, kind: .ios, name: "iPhone", publicKey: phone.publicKey, endpoints: [])

    func signed(_ path: String, as member: MemberIdentity = phone) throws -> HTTPReply {
      let headers = try member.signer.headers(method: "GET", target: path).merging(["X-Woven-Protocol": String(CompanionProtocol.version)]) { a, _ in a }
      return try send("GET", path, port: fixture.port, headers: headers)
    }
    // Unsigned or from a stranger: refused before adoption.
    #expect(try signed("/wovenmatter/v1/hello").status == 401)
    #expect(try send("GET", "/wovenmatter/v1/hello", port: fixture.port, headers: ["X-Woven-Protocol": String(CompanionProtocol.version)]).status == 401)
    // An adoption whose anchor did not sign this host's key is refused.
    let stranger = MemberDirectory(database: macDatabase, identity: try MemberIdentity.loadOrCreate(file: macRoot.appending(path: "other.key"),
      deviceID: UUID().uuidString.lowercased(), kind: .mac))
    #expect(try send("POST", "/v1/members/adopt", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(await stranger.adoption())).status == 400)

    let adopted = try send("POST", "/v1/members/adopt", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(await mac.adoption()))
    #expect(adopted.status == 200, "\(String(decoding: adopted.body, as: UTF8.self))")
    let members = try JSONDecoder().decode(LibraryMemberList.self, from: send("GET", "/v1/members", unix: fixture.socket, headers: auth).body)
    #expect(Set(members.members.map(\.deviceID)) == [identity.deviceID, mac.identity.deviceID, phone.deviceID])
    #expect(members.members.first { $0.deviceID == identity.deviceID }?.endpoints.first?.absoluteString == "https://box.tailnet.ts.net/wovenmatter/")
    let raw = try #require(send("GET", "/v1/members", unix: fixture.socket, headers: auth).json?.objectValue)
    #expect(raw["revision"]?.stringValue?.isEmpty == false)
    #expect(raw["members"]?.arrayValue?.first?.objectValue?["publicKey"]?.stringValue?.count == 44)

    let hello = try signed("/wovenmatter/v1/hello")
    #expect(hello.status == 200, "\(String(decoding: hello.body, as: UTF8.self))")
    #expect(try signed("/v1/snapshot").status == 200)
    // A signed request cannot be replayed.
    let headers = try phone.signer.headers(method: "GET", target: "/v1/hello").merging(["X-Woven-Protocol": String(CompanionProtocol.version)]) { a, _ in a }
    #expect(try send("GET", "/v1/hello", port: fixture.port, headers: headers).status == 200)
    #expect(try send("GET", "/v1/hello", port: fixture.port, headers: headers).status == 401)

    try await mac.remove(phone.deviceID)
    #expect(try send("POST", "/v1/members/adopt", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(await mac.adoption())).status == 200)
    #expect(try signed("/v1/hello").status == 401)
    let status = try #require(send("GET", "/v1/sync/status", unix: fixture.socket, headers: auth).json?.objectValue)
    #expect(status["peers"]?.arrayValue?.first?.objectValue?["deviceID"]?.stringValue == mac.identity.deviceID)
  }

  @Test func botEntriesAndLocalPublishingWriteThisLibrary() async throws {
    let fixture = try await HostFixture(); defer { fixture.remove() }
    let auth = ["Authorization": "Bearer " + fixture.token]
    let bot = UUID().uuidString.lowercased()
    let batch: GatewayJSONValue = .object([
      "bot": .object(["id": .string(bot), "name": .string("Helper")]),
      "conversations": .array([.object(["conversationId": .string("main"), "kind": .string("main"), "title": .string("Main")])]),
      "entries": .array([.object(["id": .string("00001"), "conversationId": .string("main"), "role": .string("user"),
                                  "text": .string("Hello"), "createdAt": .number(1_762_646_400_000)])])
    ])
    for _ in 0..<2 {
      let reply = try send("POST", "/v1/bots/\(bot)/entries", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(batch))
      #expect(reply.status == 200 && reply.json?.objectValue?["entries"] == .number(1), "\(String(decoding: reply.body, as: UTF8.self))")
    }
    let conversations = try await fixture.host.database.botConversations()
    #expect(conversations.count == 1 && conversations.first?.botName == "Helper" && conversations.first?.machineID == fixture.host.identity.deviceID)
    #expect(try await fixture.host.database.botEntries(machineID: fixture.host.identity.deviceID, botID: bot, conversationID: "main").count == 1)
    #expect(try send("POST", "/v1/bots/not-a-uuid/entries", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(batch)).status == 400)

    // Session history from this machine's Node server lands in its own library.
    let library = try await fixture.host.database.companionLibraryIdentity()
    // On a real host this descriptor arrives with the adding Mac's records.
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: library.libraryID,
      ownerDeviceID: library.hostDeviceID, kind: .linux, name: "Box", executionDeviceID: UUID().uuidString.lowercased())
    let conversation = UUID().uuidString.lowercased()
    let entry = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation, kind: .conversation,
      conversation: .init(id: conversation, title: "Linux session", runtimeKind: "default_agent"))
    let journal = CompanionJournalBatch(libraryID: workspace.libraryID, entries: [entry])
    #expect(try send("POST", "/v1/publisher/journal", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(journal)).status == 403)
    _ = try await fixture.host.database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: library.hostDeviceID)
    let published = try send("POST", "/v1/publisher/journal", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(journal))
    #expect(published.status == 200, "\(String(decoding: published.body, as: UTF8.self))")
    #expect(try JSONDecoder().decode(CompanionJournalBatchResult.self, from: published.body).libraryID == workspace.libraryID)
    #expect(try await fixture.host.database.companionJournal(after: 0).entries.map(\.eventID) == [entry.eventID])
    let foreign = CompanionJournalBatch(libraryID: UUID().uuidString.lowercased(), entries: [entry])
    #expect(try send("POST", "/v1/publisher/journal", unix: fixture.socket, headers: auth, body: JSONEncoder().encode(foreign)).status == 400)
  }

  /// Two Linux hosts that one Mac added synchronize through their mounted
  /// peer routes (behind a Serve-style prefix strip) with no Mac online.
  @Test func twoHostsSynchronizeThroughTheirPeerRoutes() async throws {
    final class Routes: @unchecked Sendable { var hosts: [String: LibraryHost] = [:] }
    let routes = Routes()
    let transport = LibraryPeerTransport { endpoint, request in
      guard let host = routes.hosts[endpoint.host ?? ""] else { throw URLError(.cannotConnectToHost) }
      let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
      return await host.handleNetwork(.init(method: request.method, target: String(request.target.dropFirst("/wovenmatter".count)),
                                            headers: headers, body: request.body))
    }
    let one = try await HostFixture(transport: transport), two = try await HostFixture(transport: transport)
    defer { one.remove(); two.remove() }
    routes.hosts = ["one.test": one.host, "two.test": two.host]
    let macRoot = one.directory.appending(path: "mac")
    try FileManager.default.createDirectory(at: macRoot, withIntermediateDirectories: true)
    let macDatabase = try await WorkspaceDatabase(url: macRoot.appending(path: "workspace.sqlite"))
    let mac = MemberDirectory(database: macDatabase, identity: try MemberIdentity.loadOrCreate(file: macRoot.appending(path: "mac.key"),
      deviceID: try await macDatabase.companionLibraryIdentity().hostDeviceID, kind: .mac), cacheLifetime: 0)
    try await mac.ensureSelf(name: "Offline Mac", endpoints: [URL(string: "https://mac.test/")!])
    for (fixture, name) in [(one, "one"), (two, "two")] {
      try await mac.add(deviceID: fixture.host.identity.deviceID, kind: .linux, name: name, publicKey: fixture.host.identity.publicKey,
                        endpoints: [URL(string: "https://\(name).test/wovenmatter/")!])
    }
    for fixture in [one, two] {
      #expect(try send("POST", "/v1/members/adopt", unix: fixture.socket, headers: ["Authorization": "Bearer " + fixture.token],
                       body: JSONEncoder().encode(await mac.adoption())).status == 200)
      await fixture.host.startSync()
    }
    let caller = UUID().uuidString.lowercased()
    let created = try one.call(caller, "woven_notes_create", ["title": .string("From host one")])
    let noteID = try #require(created.value["id"]?.stringValue, "\(created.error ?? "")")
    var arrived = false
    for _ in 0..<200 where !arrived {
      arrived = (try? await two.host.database.companionNote(id: noteID)) != nil
      if !arrived { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(arrived)
    let status = await two.host.sync.status()
    #expect(status.peers.first { $0.deviceID == one.host.identity.deviceID }?.state == .online)
  }
}
