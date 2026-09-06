import Foundation
import Testing
import CompanionClient
import WovenMatterCore
import WovenMatterDashboardStore

/// These tests cross the production mobile store/outbox, sync engine, JSON wire
/// DTOs, real HTTP framing, authenticated workspace API and canonical SQLite.
/// Only provider execution and deliberate reply loss are faked.
@Suite("Companion complete flows", .serialized)
@MainActor
struct CompanionFlowTests {
  @Test("online linked previews use only canonical registered links and preserve note content")
  func linkedArtifactPreview() async throws {
    var readLinks: [DatabaseArtifactLink] = []
    let fixture = try await FlowFixture(linkedData: { link in
      readLinks.append(link)
      if link.sourceID == "unavailable-remote" {
        throw CompanionAPIError(code: "linked_data_unavailable", message: "Open this remote database on the Mac.")
      }
      return DatabaseTabularData(columns: ["Value"], rows: [["Current"]], json: "[{\"Value\":\"Current\"}]")
    })
    defer { fixture.remove() }
    let link = DatabaseArtifactLink(sourceID: "registered", databaseID: "database", relativePath: "data.json")
    let tableLink = DatabaseArtifactLink(sourceID: "registered", databaseID: "database", relativePath: "table.sqlite", sqliteQuery: "SELECT value FROM items")
    var table = NoteTableBlock(rows: 1, columns: 1)
    table.databaseLink = tableLink
    let document = NoteDocument(kind: .spreadsheet, blocks: [.table(table)], databaseLink: link)
    let raw = try document.encoded()
    let id = try fixture.database.createNote(folderID: nil, content: raw)
    let before = try #require(try fixture.database.companionNote(id: id))
    func get(_ path: String) async throws -> (Data, Int) {
      var request = URLRequest(url: URL(string: fixture.http.endpoint.absoluteString + path)!)
      request.setValue("Bearer " + fixture.credential.token, forHTTPHeaderField: "Authorization")
      request.setValue("1", forHTTPHeaderField: "X-Woven-Protocol")
      request.setValue(fixture.credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
      let (data, response) = try await URLSession.shared.data(for: request)
      return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    let (bytes, status) = try await get("/v1/assets/\(id)/linked-data?path=/etc/passwd&sql=DELETE")
    #expect(status == 200)
    let live = try JSONDecoder().decode(CompanionLinkedData.self, from: bytes)
    #expect(live.noteRevision == before.revision && live.noteID == id)
    #expect(live.rows == [["Current"]] && readLinks == [link])
    let (_, tableStatus) = try await get("/v1/assets/\(id)/linked-data?tableID=\(table.id)")
    #expect(tableStatus == 200 && readLinks == [link, tableLink])
    let (_, missingStatus) = try await get("/v1/assets/\(id)/linked-data?tableID=unknown")
    #expect(missingStatus == 404 && readLinks.count == 2)
    #expect(try fixture.database.companionNote(id: id) == before)
    var remote = document
    remote.databaseLink?.sourceID = "unavailable-remote"
    let remoteID = try fixture.database.createNote(folderID: nil, content: remote.encoded())
    let (errorBytes, remoteStatus) = try await get("/v1/assets/\(remoteID)/linked-data")
    #expect(remoteStatus == 400)
    #expect(try JSONDecoder().decode(CompanionAPIError.self, from: errorBytes).code == "linked_data_unavailable")
  }

  @Test("offline rich folder/note capture survives mobile restart and a lost server acknowledgement")
  func offlineCaptureAndLostAck() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let folder = try await fixture.mobile.createFolder(name: "Ideas")
    let content = try richDocument("Captured without internet")
    let note = try await fixture.mobile.createNote(folderID: folder.id, title: "Idea", content: content)
    let restarted = try MobileStore(file: fixture.mobileURL)
    #expect(await restarted.snapshot().notes[note.id]?.content == content)
    await fixture.transport.dropNextMutationAcknowledgement(resourceID: note.id)
    let engine = MobileSyncEngine(store: restarted, transport: fixture.transport)
    do { try await engine.synchronize(); Issue.record("Expected a lost acknowledgement") }
    catch MobileConnectionError.offline {}
    #expect(try fixture.database.companionNote(id: note.id)?.content == content)
    #expect(await restarted.snapshot().outbox.count == 1)
    let secondRestart = try MobileStore(file: fixture.mobileURL)
    try await MobileSyncEngine(store: secondRestart, transport: fixture.transport).synchronize()
    let canonical = try fixture.database.companionSnapshot()
    #expect(canonical.notes.count == 1 && canonical.folders.count == 1)
    #expect(canonical.notes[0].id == note.id && canonical.notes[0].content == content)
    #expect(await secondRestart.snapshot().outbox.isEmpty)
    let cached = try #require(await secondRestart.snapshot().notes[note.id])
    #expect(cached.revision == canonical.notes[0].revision && cached.content == content)
    #expect(try NoteDocument.editableDocument(from: cached.content).blocks.count == 2)
    #expect(await fixture.transport.count("POST /v1/mutations") == 3)
  }

  @Test("desktop conflict and offline deletion retain base/local/remote writing with distinct recovery identity")
  func conflictAndDeletion() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let baseContent = try richDocument("Base")
    let note = try await fixture.mobile.createNote(folderID: nil, title: "Draft", content: baseContent)
    let engine = MobileSyncEngine(store: fixture.mobile, transport: fixture.transport)
    try await engine.synchronize()
    let displayed = try #require(await fixture.mobile.snapshot().notes[note.id])
    let localContent = try richDocument("Phone writing")
    try await fixture.mobile.editNote(id: note.id, title: "Phone", content: localContent, folderID: nil, base: displayed)
    let remoteContent = try richDocument("Mac writing")
    _ = try fixture.database.persistNoteDraft(id: note.id, title: "Mac", content: remoteContent, expectedRevision: String(displayed.revision))
    try await engine.synchronize()
    let conflict = try #require(await fixture.mobile.snapshot().conflicts[note.id])
    #expect(conflict.base?.content == baseContent)
    #expect(conflict.local.content == localContent && conflict.remote?.content == remoteContent)
    #expect(try fixture.database.companionNote(id: note.id)?.content == remoteContent)
    let recovered = try await fixture.mobile.preserveConflictAsCopy(id: note.id)
    #expect(recovered.id != note.id && recovered.content == localContent)
    try await engine.synchronize()
    let copied = try #require(await fixture.mobile.snapshot().notes[recovered.id])
    try await fixture.mobile.editNote(id: copied.id, title: "Last offline writing", content: richDocument("Keep after deletion"), folderID: copied.folderID, base: copied)
    _ = try fixture.database.applyCompanionMutation(CompanionMutation(deviceID: fixture.credential.deviceID, kind: .deleteNote, resourceID: copied.id, expectedRevision: copied.revision))
    try await engine.synchronize()
    #expect(try fixture.database.companionNote(id: copied.id) == nil)
    let deletedConflict = try #require(await fixture.mobile.snapshot().conflicts[copied.id])
    #expect(try NoteDocument.editableDocument(from: deletedConflict.local.content).plainText.contains("Keep after deletion"))
    #expect(deletedConflict.remote == nil)
    #expect(try fixture.database.companionSnapshot().notes.count == 1)
  }

  @Test("large conflict keeps the fetched remote body when the feed repeats metadata-only invalidation")
  func largeConflictBody() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let note = try await fixture.mobile.createNote(folderID: nil, title: "Large base", content: richDocument(String(repeating: "base ", count: 70_000)))
    let engine = MobileSyncEngine(store: fixture.mobile, transport: fixture.transport)
    try await engine.synchronize()
    let displayed = try #require(await fixture.mobile.snapshot().notes[note.id])
    let local = try richDocument(String(repeating: "phone ", count: 70_000))
    try await fixture.mobile.editNote(id: note.id, title: "Large phone", content: local, folderID: nil, base: displayed)
    let remote = try richDocument(String(repeating: "mac ", count: 90_000))
    _ = try fixture.database.persistNoteDraft(id: note.id, title: "Large Mac", content: remote, expectedRevision: String(displayed.revision))
    try await engine.synchronize()
    let conflict = try #require(await fixture.mobile.snapshot().conflicts[note.id])
    #expect(conflict.local.content == local)
    #expect(conflict.remote?.contentIncluded == true)
    #expect(conflict.remote?.content == remote)
    let restarted = try MobileStore(file: fixture.mobileURL)
    #expect(await restarted.snapshot().conflicts[note.id]?.remote?.content == remote)
  }

  @Test("workspace, protocol and revocation failures happen before offline outbox dispatch")
  func identityBeforeMutation() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let unauthenticatedSession = URLSession(configuration: .ephemeral)
    var unauthenticated = URLRequest(url: URL(string: fixture.http.endpoint.absoluteString + "/v1/hello")!)
    unauthenticated.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    unauthenticated.setValue(fixture.credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    let (deniedBody, deniedResponse) = try await unauthenticatedSession.data(for: unauthenticated)
    unauthenticatedSession.finishTasksAndInvalidate()
    #expect((deniedResponse as? HTTPURLResponse)?.statusCode == 401)
    #expect(try JSONDecoder().decode(CompanionAPIError.self, from: deniedBody).code == "unauthorized")
    let engine = MobileSyncEngine(store: fixture.mobile, transport: fixture.transport)
    try await engine.synchronize()
    _ = try await fixture.mobile.createNote(folderID: nil, title: "Retain offline", content: richDocument("Private writing"))
    let wrongDB = try WorkspaceDatabase(url: fixture.directory.appending(path: "other-workspace.sqlite"))
    let wrongCommands = FakeCommands(database: wrongDB)
    let wrongAPI = CompanionWorkspaceAPI(database: wrongDB, authentication: fixture.authentication, commands: wrongCommands, isActive: { true })
    let wrongServer = try await FlowHTTPServer(api: wrongAPI)
    defer { wrongServer.stop() }
    let wrongTransport = APITransport(serverURL: wrongServer.endpoint, credential: fixture.credential)
    do { try await MobileSyncEngine(store: fixture.mobile, transport: wrongTransport).synchronize(); Issue.record("Expected workspace mismatch") }
    catch MobileConnectionError.http(409, _) {}
    #expect(await wrongTransport.count("POST /v1/mutations") == 0)
    #expect(try wrongDB.companionSnapshot().notes.isEmpty)
    #expect(await fixture.mobile.snapshot().outbox.count == 1)
    let incompatible = APITransport(serverURL: fixture.http.endpoint, credential: fixture.credential, protocolVersion: 99)
    do { try await MobileSyncEngine(store: fixture.mobile, transport: incompatible).synchronize(); Issue.record("Expected incompatible protocol") }
    catch MobileConnectionError.http(426, _) {}
    #expect(await incompatible.count("POST /v1/mutations") == 0)
    try await fixture.authentication.revoke(deviceID: fixture.credential.deviceID)
    do { try await engine.synchronize(); Issue.record("Expected revoked access") }
    catch MobileConnectionError.http(401, _) {}
    #expect(await fixture.mobile.snapshot().outbox.count == 1)
    let reopened = try MobileStore(file: fixture.mobileURL)
    #expect(await reopened.snapshot().notes.values.first?.title == "Retain offline")
  }

  @Test("new chat and first note-bound prompt each execute once after lost ACKs on both phases")
  func twoPhaseNewChatLostAcknowledgements() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let folder = try await fixture.mobile.createFolder(name: "Offline ideas")
    let initialBody = try richDocument("Offline idea before opening a chat")
    let note = try await fixture.mobile.createNote(folderID: folder.id, title: "Plan", content: initialBody)
    let conversationID = UUID().uuidString.lowercased()
    let launch = MobileLaunchRecord(
      create: CompanionCommand(deviceID: fixture.credential.deviceID, kind: .createSession,
          conversationID: conversationID, providerID: "local:codex", runtimeKind: "codex", folderID: folder.id, text: "Phone-created chat"),
      initialSend: CompanionCommand(deviceID: fixture.credential.deviceID, kind: .send,
          conversationID: conversationID, text: "Use this selected note for the first prompt", noteID: note.id)
    )
    #expect(try fixture.database.companionSnapshot().conversations.isEmpty)
    await fixture.transport.dropNextCommandAcknowledgement(commandID: launch.create.commandID)
    do { _ = try await MobileSyncEngine(store: fixture.mobile, transport: fixture.transport).startConversation(launch); Issue.record("Expected create-phase ACK loss") }
    catch MobileConnectionError.offline {}
    let afterCreate = try fixture.database.companionSnapshot()
    #expect(afterCreate.conversations.count == 1 && afterCreate.conversations.first?.id == conversationID)
    #expect(afterCreate.conversations.first?.folderID == folder.id)
    #expect(afterCreate.notes.count == 1 && afterCreate.folders.count == 1)
    #expect(try fixture.database.conversationContent(id: conversationID).runs.isEmpty)
    let restarted = try MobileStore(file: fixture.mobileURL)
    let nextEngine = MobileSyncEngine(store: restarted, transport: fixture.transport)
    try await nextEngine.recoverCommandReceipts()
    let recoveredCreate = try #require(await restarted.snapshot().launches.first)
    #expect(recoveredCreate.createReceipt?.status == .completed)
    #expect(!recoveredCreate.sendPrepared && recoveredCreate.sendReceipt == nil)
    #expect(await fixture.transport.count("POST /v1/commands") == 1)
    // Receipt recovery must not automatically send the first prompt. The user
    // can keep writing and explicitly continue with the same durable launch.
    let displayed = try #require(await restarted.snapshot().notes[note.id])
    let latestBody = try richDocument("Latest writing before explicit Continue")
    try await restarted.editNote(id: note.id, title: "Latest plan", content: latestBody, folderID: folder.id, base: displayed)
    await fixture.transport.dropNextCommandAcknowledgement(commandID: launch.initialSend.commandID)
    do { _ = try await nextEngine.startConversation(launch); Issue.record("Expected first-prompt ACK loss") }
    catch MobileConnectionError.offline {}
    let canonical = try #require(try fixture.database.companionNote(id: note.id))
    #expect(canonical.revision == displayed.revision + 1 && canonical.content == latestBody)
    #expect(fixture.commands.received.map(\.kind) == [.createSession, .send])
    #expect(fixture.commands.received.last?.noteRevision == canonical.revision)
    #expect(fixture.commands.boundNoteContents == [latestBody])
    let finalRestart = try MobileStore(file: fixture.mobileURL)
    let finalEngine = MobileSyncEngine(store: finalRestart, transport: fixture.transport)
    try await finalEngine.recoverCommandReceipts()
    let recovered = try #require(await finalRestart.snapshot().launches.first)
    #expect(recovered.accepted && recovered.sendReceipt?.status == .completed)
    #expect(await fixture.transport.count("POST /v1/commands") == 2)
    let explicitRepeat = try await finalEngine.startConversation(launch)
    #expect(explicitRepeat.accepted)
    #expect(await fixture.transport.count("POST /v1/commands") == 2)
    let content = try fixture.database.conversationContent(id: conversationID)
    #expect(content.runs.count == 1)
    #expect(content.messages.filter { $0.role == "user" }.map(\.content) == [launch.initialSend.text!])
    #expect(try fixture.database.companionSnapshot().conversations.count == 1)
    let requests = await fixture.http.observations.requests()
    #expect(requests.contains("POST /wovenmatter/v1/pair"))
    #expect(requests.contains("GET /wovenmatter/v1/command-receipts/" + launch.create.commandID))
    #expect(requests.contains("GET /wovenmatter/v1/command-receipts/" + launch.initialSend.commandID))
    #expect(requests.allSatisfy { $0.contains(" /wovenmatter/v1/") })
  }

  @Test("note-bound command flushes latest note and mobile restart only GETs a lost command receipt")
  func freshNoteAndCommandReceipt() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let note = try await fixture.mobile.createNote(folderID: nil, title: "Plan", content: richDocument("Use this idea"))
    let conversationID = try fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Fixture session", ownerDeviceID: UUID())
    let engine = MobileSyncEngine(store: fixture.mobile, transport: fixture.transport)
    let command = CompanionCommand(deviceID: fixture.credential.deviceID, kind: .send, conversationID: conversationID, text: "Work from my note", noteID: note.id)
    await fixture.transport.dropNextCommandAcknowledgement()
    do { _ = try await engine.submit(command); Issue.record("Expected a lost command acknowledgement") }
    catch MobileConnectionError.offline {}
    #expect(fixture.commands.received.count == 1)
    let accepted = try #require(fixture.commands.received.first)
    let canonical = try #require(try fixture.database.companionNote(id: note.id))
    #expect(accepted.noteRevision == canonical.revision)
    #expect(fixture.commands.boundNoteContents == [canonical.content])
    let restarted = try MobileStore(file: fixture.mobileURL)
    try await MobileSyncEngine(store: restarted, transport: fixture.transport).recoverCommandReceipts()
    #expect(await fixture.transport.count("POST /v1/commands") == 1)
    #expect(await fixture.transport.count("GET /v1/command-receipts/" + command.commandID) == 1)
    #expect(await restarted.snapshot().commands.first?.receipt?.status == .completed)
    #expect(fixture.commands.received.count == 1)
  }

  @Test("disconnect and host stop reject new writes while an accepted Mac-owned run completes")
  func stoppedHostKeepsAcceptedWork() async throws {
    let fixture = try await FlowFixture(); defer { fixture.remove() }
    let conversationID = try fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Long fake run", ownerDeviceID: UUID())
    fixture.commands.holdCommands = true
    let engine = MobileSyncEngine(store: fixture.mobile, transport: fixture.transport)
    let command = CompanionCommand(deviceID: fixture.credential.deviceID, kind: .send, conversationID: conversationID, text: "Continue on Mac")
    let sending = Task { try await engine.submit(command) }
    await fixture.commands.waitUntilStarted()
    #expect(try fixture.database.activeDeviceOwnedConversationIDs().contains(conversationID))
    sending.cancel() // The HTTP client's task does not own the retained dispatcher work.
    fixture.activity.active = false
    let pending = try await fixture.mobile.createNote(folderID: nil, title: "Offline while stopped", content: richDocument("Saved locally"))
    do { try await engine.synchronize(); Issue.record("Expected stopped host") }
    catch MobileConnectionError.http(503, _) {}
    #expect(try fixture.database.companionNote(id: pending.id) == nil)
    #expect(await fixture.mobile.snapshot().notes[pending.id]?.title == "Offline while stopped")
    fixture.http.stop()
    fixture.commands.release()
    await fixture.commands.waitUntilCompleted()
    do { _ = try await sending.value; Issue.record("Cancelled HTTP delivery should not return a receipt") }
    catch let error as URLError { #expect(error.code == .cancelled || error.code == .networkConnectionLost) }
    let receipt = try #require(try fixture.database.companionCommandReceipt(deviceID: command.deviceID, commandID: command.commandID))
    #expect(receipt.status == .completed)
    #expect(fixture.commands.received.count == 1)
    #expect(try fixture.database.activeDeviceOwnedConversationIDs().isEmpty)
  }

  private func richDocument(_ text: String) throws -> String {
    let run = NoteTextRun(text: text, bold: true, link: "https://example.com/idea")
    var table = NoteTableBlock(rows: 2, columns: 2, headerRow: true)
    table.rows[0].cells[0].runs = [.init(text: "Stable cell")]
    return try NoteDocument(blocks: [.richText(.init(style: .heading2, runs: [run])), .table(table)]).encoded()
  }
}

@MainActor
private final class FlowActivity { var active = true }

@MainActor
private final class FlowFixture {
  let directory: URL
  let database: WorkspaceDatabase
  let mobileURL: URL
  let mobile: MobileStore
  let authentication: CompanionAuthentication
  let commands: FakeCommands
  let activity: FlowActivity
  let api: CompanionWorkspaceAPI
  let credential: MobileCredential
  let http: FlowHTTPServer
  let transport: APITransport
  init(linkedData: @escaping @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData = { _ in
    throw CompanionAPIError(code: "linked_data_unavailable", message: "Unavailable fixture database")
  }) async throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "woven-companion-flow-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    mobileURL = directory.appending(path: "phone/store.json")
    mobile = try MobileStore(file: mobileURL)
    authentication = try CompanionAuthentication(fileURL: directory.appending(path: "devices.json"))
    commands = FakeCommands(database: database)
    activity = FlowActivity()
    api = CompanionWorkspaceAPI(database: database, authentication: authentication, commands: commands, isActive: { [activity] in activity.active }, linkedData: linkedData)
    http = try await FlowHTTPServer(api: api)
    let endpoint = URL(string: "https://fixture.test-tailnet.ts.net/wovenmatter")!
    let offer = try await authentication.createOffer(endpoint: endpoint)
    let deviceID = await mobile.snapshot().deviceID
    let pair = CompanionPairRequest(token: offer.payload.token, deviceID: deviceID, deviceName: "Fixture iPhone")
    var request = URLRequest(url: URL(string: http.endpoint.absoluteString + "/v1/pair")!)
    request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(pair)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let session = URLSession(configuration: .ephemeral)
    let (bytes, response) = try await session.data(for: request)
    session.finishTasksAndInvalidate()
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MobileConnectionError.invalidResponse }
    let result = try JSONDecoder().decode(CompanionPairResponse.self, from: bytes)
    credential = MobileCredential(endpoint: endpoint, workspaceID: result.workspaceID, deviceID: result.deviceID, token: result.credential)
    transport = APITransport(serverURL: http.endpoint, credential: credential)
  }
  func remove() { http.stop(); try? FileManager.default.removeItem(at: directory) }
}

private actor FlowHTTPObservations {
  private var targets: [String] = []
  func record(_ request: CompanionHTTPRequest) { targets.append(request.method + " " + request.target) }
  func requests() -> [String] { targets }
}
private final class FlowHTTPServer: Sendable {
  let server: CompanionHTTPServer
  let endpoint: URL
  let observations: FlowHTTPObservations
  init(api: CompanionWorkspaceAPI) async throws {
    let observations = FlowHTTPObservations()
    self.observations = observations
    server = CompanionHTTPServer { request in
      await observations.record(request)
      return await api.handle(request)
    }
    let port = try await server.start()
    endpoint = URL(string: "http://127.0.0.1:\(port)/wovenmatter")!
  }
  func stop() { server.stop() }
}

/// Test-only mapping from a valid HTTPS credential to a real loopback listener.
/// Production HTTPSCompanionTransport remains unchanged and rejects localhost.
/// URLSession drives the actual HTTP parser, mount routing and response framing.
/// An injected reply loss occurs after those layers commit/return, before the
/// mobile engine can durably acknowledge the result.
private actor APITransport: CompanionTransport {
  let serverURL: URL
  let session: URLSession
  let credential: MobileCredential
  let protocolVersion: Int
  var calls: [String: Int] = [:]
  var dropMutationResource: String?
  var dropCommand = false
  var dropCommandID: String?
  init(serverURL: URL, credential: MobileCredential, protocolVersion: Int = CompanionProtocol.version) {
    precondition(serverURL.scheme == "http" && serverURL.host == "127.0.0.1" && serverURL.path == "/wovenmatter")
    precondition(CompanionPairingPayload.isValidEndpoint(credential.endpoint))
    self.serverURL = serverURL; self.credential = credential; self.protocolVersion = protocolVersion
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
    session = URLSession(configuration: configuration)
  }
  deinit { session.invalidateAndCancel() }
  func count(_ key: String) -> Int { calls[key, default: 0] }
  func dropNextMutationAcknowledgement(resourceID: String) { dropMutationResource = resourceID }
  func dropNextCommandAcknowledgement(commandID: String? = nil) {
    if let commandID { dropCommandID = commandID } else { dropCommand = true }
  }
  func workspaceIdentity() async throws -> String { let value: CompanionHello = try await request("/v1/hello"); return value.workspaceID }
  func snapshot() async throws -> CompanionSnapshot { try await request("/v1/snapshot") }
  func changes(after: Int64) async throws -> CompanionChangePage { try await request("/v1/changes?after=\(after)&limit=200") }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult {
    let result: CompanionMutationResult = try await request("/v1/mutations", method: "POST", body: JSONEncoder().encode(mutation))
    if dropMutationResource == mutation.resourceID { dropMutationResource = nil; throw MobileConnectionError.offline }
    return result
  }
  func note(_ id: String) async throws -> CompanionNote { try await request("/v1/notes/\(id)") }
  func providers() async throws -> [CompanionProvider] { try await request("/v1/providers") }
  func pending() async throws -> [CompanionPendingInteraction] { try await request("/v1/pending") }
  func transcript(_ id: String) async throws -> CompanionTranscript { try await request("/v1/sessions/\(id)/transcript") }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    let result: CompanionCommandReceipt = try await request("/v1/commands", method: "POST", body: JSONEncoder().encode(command))
    if dropCommand || dropCommandID == command.commandID { dropCommand = false; dropCommandID = nil; throw MobileConnectionError.offline }
    return result
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
    do { return try await request("/v1/command-receipts/\(id)") }
    catch MobileConnectionError.http(404, _) { return nil }
  }
  private func request<Value: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data = Data()) async throws -> Value {
    calls[method + " " + path, default: 0] += 1
    var request = URLRequest(url: URL(string: serverURL.absoluteString + path)!)
    request.httpMethod = method
    if method == "POST" { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
    request.setValue(credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    request.setValue(String(protocolVersion), forHTTPHeaderField: "X-Woven-Protocol")
    let (bytes, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard response.statusCode == 200 else {
      let error = try JSONDecoder().decode(CompanionAPIError.self, from: bytes)
      throw MobileConnectionError.http(response.statusCode, error.message)
    }
    guard Int(response.value(forHTTPHeaderField: "Content-Length") ?? "") == bytes.count else {
      throw MobileConnectionError.invalidResponse
    }
    return try JSONDecoder().decode(Value.self, from: bytes)
  }
}

@MainActor
private final class FakeCommands: CompanionCommandServing {
  let database: WorkspaceDatabase
  let dispatcher: CompanionCommandDispatcher
  var received: [CompanionCommand] = []
  var boundNoteContents: [String] = []
  var holdCommands = false
  private var started = false
  private var completed = false
  private var completedWaiter: CheckedContinuation<Void, Never>?
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  init(database: WorkspaceDatabase) { self.database = database; dispatcher = CompanionCommandDispatcher(database: database) }
  func providers() -> [CompanionProvider] { [.init(id: "local:codex", runtimeKind: "codex", displayName: "Fixture Codex", available: true)] }
  func pendingInteractions() -> [CompanionPendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { providers()[0] }
  func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript {
    let content = try database.conversationContent(id: conversationID)
    return CompanionTranscript(conversationID: conversationID, messages: content.messages.map {
      .init(id: $0.id, conversationID: $0.conversationID, runID: $0.runID, role: $0.role, content: $0.content, status: $0.status, createdAt: $0.createdAt)
    })
  }
  func receipt(commandID: String, deviceID: String) throws -> CompanionCommandReceipt? { try dispatcher.receipt(commandID: commandID, deviceID: deviceID) }
  func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
    let result = try await dispatcher.execute(command) { [self] accepted in
      received.append(command)
      guard let conversationID = command.conversationID else { throw MobileConnectionError.invalidResponse }
      var receipt = accepted
      switch command.kind {
      case .createSession:
        guard command.providerID == "local:codex" else { throw MobileConnectionError.invalidResponse }
        _ = try database.createLocalACPSession(runtimeKind: .codex,
            title: command.text ?? "Fixture mobile conversation", ownerDeviceID: UUID(),
            conversationID: conversationID, folderID: command.folderID)
        receipt.conversationID = conversationID
        return receipt
      case .send:
        if let noteID = command.noteID {
          guard let note = try database.companionNote(id: noteID), note.revision == command.noteRevision else { throw MobileStore.Failure.conflictingNote }
          boundNoteContents.append(note.content)
        }
        let run = try database.beginLocalACPRun(conversationID: conversationID, content: command.text ?? "")
        started = true; startedWaiter?.resume(); startedWaiter = nil
        if holdCommands { await withCheckedContinuation { releaseWaiter = $0 } }
        try database.completeLocalACPRun(runID: run.runID)
        receipt.conversationID = conversationID; receipt.runID = run.runID
        return receipt
      case .steer, .stop, .respond:
        throw CompanionAPIError(code: "fixture_unsupported", message: "This fake only implements createSession and send.")
      }
    }
    completed = true; completedWaiter?.resume(); completedWaiter = nil
    return result
  }
  func waitUntilCompleted() async {
    if completed { return }
    await withCheckedContinuation { completedWaiter = $0 }
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }
  func release() { holdCommands = false; releaseWaiter?.resume(); releaseWaiter = nil }
}
