import Foundation
import CryptoKit
import Testing
import CompanionClient
import WovenMatterCore
import WovenMatterDashboardStore

/// These flows cross the durable portable journal, real pairing/authentication,
/// production API routes and central SQLite. Only transport reply loss and the
/// remote execution source are controlled; no model providers are contacted.
@Suite("Federated execution complete flows", .serialized)
@MainActor
struct FederatedExecutionFlowTests {
  @Test("both libraries keep paired clients and offline origin work after central activation")
  func centralTransferWithOfflineClients() async throws {
    let source = try await FederationFlowFixture(), target = try await FederationFlowFixture()
    defer { source.remove(); target.remove() }
    let a = try await source.client("old-library-client"), b = try await target.client("new-library-client")
    let aID = await a.store.snapshot().deviceID, bID = await b.store.snapshot().deviceID
    let aWorkspace = CompanionExecutionWorkspace(id: aID, libraryID: source.libraryID, ownerDeviceID: aID, kind: .mac, name: "Source node")
    let bWorkspace = CompanionExecutionWorkspace(id: bID, libraryID: target.libraryID, ownerDeviceID: bID, kind: .mac, name: "Destination node")
    try await a.store.journal.upsertWorkspace(aWorkspace); try await b.store.journal.upsertWorkspace(bWorkspace)
    func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(text: text))]).encoded() }
    let noteA = try await a.store.createNote(folderID: nil, title: "From source", content: content("Source library"))
    let noteB = try await b.store.createNote(folderID: nil, title: "From destination", content: content("Destination library"))
    _ = try await a.store.journal.append(workspaceID: aID, conversation: .init(id: UUID().uuidString.lowercased(), title: "Before transfer", libraryID: source.libraryID, workspaceID: aID))
    try await MobileSyncEngine(store: a.store, transport: a.transport).synchronize()
    try await MobileSyncEngine(store: b.store, transport: b.transport).synchronize()
    // This device is disconnected while the two central databases are merged.
    let offline = try await a.store.createNote(folderID: nil, title: "Offline during move", content: content("Keep this exact writing"))
    let offlineConversation = UUID().uuidString.lowercased()
    let pending = try await a.store.journal.append(workspaceID: aID, conversation: .init(id: offlineConversation, title: "Offline execution", libraryID: source.libraryID, workspaceID: aID))
    let transferID = UUID().uuidString.lowercased(), incoming = source.directory.appending(path: "source-backup.sqlite"), merged = target.directory.appending(path: "merged.sqlite")
    try await source.database.backupLibrary(to: incoming); try await target.database.backupLibrary(to: merged)
    _ = try LibraryTransferSQLite.merge(source: incoming, into: merged, transferID: transferID, sourceLibraryID: source.libraryID, destinationLibraryID: target.libraryID)
    let staged = try await WorkspaceDatabase(url: merged)
    try await staged.installLibraryTransferAlias(.init(transferID: transferID, previousLibraryID: source.libraryID,
      endpoint: URL(string: "https://mini.test-tailnet.ts.net/wovenmatter")!, libraryID: target.libraryID))
    try await target.database.fenceLibraryTransfer(transferID)
    try await target.authentication.mergeTransferredDevices(source.authentication.transferDevices())
    try await target.database.activateTransferredLibrary(from: merged, transferID: transferID)
    try await target.database.releaseLibraryTransfer(transferID)
    a.transport.api = target.api; a.transport.canonicalLibraryID = target.libraryID; a.transport.relocationID = transferID
    a.transport.dropNextJournalAcknowledgement = true
    let reconnect = try MobileStore(file: a.file)
    do { try await MobileSyncEngine(store: reconnect, transport: a.transport).synchronize(); Issue.record("Expected a lost new-central acknowledgement") }
    catch MobileConnectionError.offline {}
    let restarted = try MobileStore(file: a.file)
    try await MobileSyncEngine(store: restarted, transport: a.transport).synchronize()
    try await MobileSyncEngine(store: b.store, transport: b.transport).synchronize()
    for note in [noteA, noteB, offline] {
      #expect(try await target.database.companionNote(id: note.id)?.content == note.content)
      #expect(await restarted.snapshot().notes[note.id]?.content == note.content)
      #expect(await b.store.snapshot().notes[note.id]?.content == note.content)
    }
    #expect(await restarted.snapshot().outbox.isEmpty)
    #expect(await restarted.journal.snapshot().pendingEventIDs.isEmpty)
    let published = try await target.database.companionJournal(after: 0).entries
    #expect(pending.allSatisfy { entry in published.filter { $0.eventID == entry.eventID }.count == 1 })
    #expect(try await source.database.companionNote(id: noteB.id) == nil)
    #expect(source.commands.executions == 0 && target.commands.executions == 0)
  }

  @Test("offline execution survives lost central acknowledgement and restart without re-execution")
  func offlineExecutionLostAcknowledgement() async throws {
    let fixture = try await FederationFlowFixture()
    defer { fixture.remove() }
    let owner = try await fixture.client("phone")
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: fixture.libraryID,
      ownerDeviceID: owner.credential.deviceID, kind: .ios, name: "This iPhone")
    try await owner.store.journal.upsertWorkspace(workspace)
    let conversationID = UUID().uuidString.lowercased()
    let runID = UUID().uuidString.lowercased()
    let conversation = CompanionConversation(id: conversationID, title: "Created with central Mac offline",
      runtimeKind: "default_agent", activeRunID: runID, libraryID: fixture.libraryID, workspaceID: workspace.id)
    try await owner.store.journal.append(workspaceID: workspace.id, conversation: conversation)
    // More than one wire page, with distinct identities and lossless message bodies.
    let messages = (0..<225).map { index in
      CompanionMessage(id: UUID().uuidString.lowercased(), conversationID: conversationID, runID: runID,
        role: index.isMultiple(of: 2) ? "user" : "assistant", content: "Offline history item \(index): " + String(repeating: "α", count: 32), status: "completed")
    }
    for message in messages {
      try await owner.store.journal.append(workspaceID: workspace.id,
        transcript: .init(conversationID: conversationID, messages: [message], activeRunID: runID))
    }
    try await owner.store.journal.append(workspaceID: workspace.id, transcript: .init(conversationID: conversationID))
    // A complete raw tool-history record exceeds both one event and one read page.
    // The journal carries immutable parts rather than truncating it into a preview.
    let nativeBytes = Data(String(repeating: "tool result with full detail\n", count: 340_000).utf8)
    let recordID = UUID().uuidString.lowercased()
    let hash = SHA256.hash(data: nativeBytes).map { String(format: "%02x", $0) }.joined()
    let partSize = 512 * 1_024
    let partCount = (nativeBytes.count + partSize - 1) / partSize
    for index in 0..<partCount {
      let start = index * partSize
      let part = CompanionNativeRecordPart(recordID: recordID, format: "pi-durable.message", partIndex: index,
        partCount: partCount, byteCount: Int64(nativeBytes.count), sha256: hash,
        data: nativeBytes.subdata(in: start..<min(start + partSize, nativeBytes.count)))
      let sequence = (await owner.store.journal.snapshot().originSequences[workspace.id] ?? 0) + 1
      try await owner.store.journal.record(.init(workspaceID: workspace.id, originSequence: sequence,
        conversationID: conversationID, runID: runID, kind: .nativeRecord, nativeRecord: part))
    }
    #expect(try await fixture.database.companionSnapshot().conversations.isEmpty)
    #expect(await owner.store.journal.snapshot().pendingEventIDs.count > 200)

    owner.transport.dropNextJournalAcknowledgement = true
    do {
      try await MobileSyncEngine(store: owner.store, transport: owner.transport).synchronize()
      Issue.record("Expected central reply loss after committing the first page")
    } catch MobileConnectionError.offline {}
    #expect(try await fixture.database.companionJournal(after: 0).entries.count == 200)
    #expect(await owner.store.journal.snapshot().pendingEventIDs.count > 200)

    let restarted = try MobileStore(file: owner.file)
    try await MobileSyncEngine(store: restarted, transport: owner.transport).synchronize()
    #expect(await restarted.journal.snapshot().pendingEventIDs.isEmpty)
    let archived = try #require(try await fixture.database.companionFederatedTranscript(conversationID: conversationID))
    var archivedMessages = archived.messages
    var olderCursor = archived.olderCursor
    var transcriptPages = 1
    while let cursor = olderCursor {
      let page = try #require(try await fixture.database.companionFederatedTranscript(conversationID: conversationID, before: cursor))
      archivedMessages = page.messages + archivedMessages
      olderCursor = page.olderCursor; transcriptPages += 1
      #expect(transcriptPages <= 3)
    }
    #expect(transcriptPages == 3)
    #expect(archivedMessages == messages)
    #expect(archived.activeRunID == nil)
    #expect(fixture.commands.executions == 0)
    #expect(owner.transport.journalImports >= 4) // lost ACK, duplicate, then byte-bounded native-history batches

    let otherMac = try await fixture.client("other-mac")
    try await MobileSyncEngine(store: otherMac.store, transport: otherMac.transport).synchronize()
    #expect(await otherMac.store.journal.snapshot().transcripts[conversationID]?.messages == messages)
    #expect(await otherMac.store.snapshot().conversations[conversationID]?.workspaceID == workspace.id)
    let importedParts = await otherMac.store.journal.snapshot().entries.values.compactMap(\.nativeRecord)
      .filter { $0.recordID == recordID }.sorted { $0.partIndex < $1.partIndex }
    #expect(importedParts.count == partCount)
    #expect(importedParts.reduce(into: Data()) { $0.append($1.data) } == nativeBytes)
    var centralBytes = Data()
    for index in 0..<partCount {
      let part = try #require(try await fixture.database.companionNativeHistoryPart(workspaceID: workspace.id, recordID: recordID, partIndex: index))
      centralBytes.append(part.data)
    }
    #expect(centralBytes == nativeBytes)
    #expect(fixture.commands.executions == 0)
    // Opening either replica never upgrades it into a second central database.
    #expect(await otherMac.store.snapshot().workspaceID == fixture.libraryID)
  }

  @Test("observers retain remote history but only its execution workspace publishes centrally")
  func ownerPublicationAndObserverIsolation() async throws {
    let fixture = try await FederationFlowFixture()
    defer { fixture.remove() }
    let phone = try await fixture.client("observer-phone")
    let mac = try await fixture.client("observer-mac")
    let identity = try await fixture.database.companionLibraryIdentity()
    var workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: fixture.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Linux",
      // Deliberately collide with a paired client's ID: only the dedicated
      // publisher credential may publish Linux history, even in this case.
      executionDeviceID: mac.credential.deviceID,
      journalDeviceIDs: [phone.credential.deviceID, mac.credential.deviceID])
    workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let grant = try await fixture.database.issueCompanionWorkspacePublisher(workspaceID: workspace.id,
      endpoint: URL(string: "https://central.test-tailnet.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
    let conversationID = UUID().uuidString.lowercased()
    let conversation = CompanionConversation(id: conversationID, title: "One execution owner", workspaceID: workspace.id)
    let message = CompanionMessage(id: UUID().uuidString.lowercased(), conversationID: conversationID,
      role: "assistant", content: "Saved on the Linux workspace while the central Mac was offline.")
    let entries = [
      CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversationID,
        kind: .conversation, conversation: conversation),
      CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: conversationID,
        kind: .transcript, transcript: .init(conversationID: conversationID, messages: [message]))
    ]
    let batch = CompanionJournalBatch(libraryID: fixture.libraryID, entries: entries)
    let source = RecordedExecutionSource(workspace: workspace, entries: entries)
    for client in [phone, mac] {
      try await WorkspaceClient(store: client.store, workspaceID: workspace.id, transport: source).refresh()
      #expect(await client.store.snapshot().transcripts[conversationID]?.messages == [message])
      // Reproduce a previous-build cache whose foreign records were marked pending.
      for entry in entries { try await client.store.journal.record(entry) }
      try await MobileSyncEngine(store: client.store, transport: client.transport).synchronize()
      #expect(await client.store.journal.snapshot().pendingEventIDs.isEmpty)
      #expect(await client.store.snapshot().transcripts[conversationID]?.messages == [message])
      #expect(client.transport.journalImports == 0)
      do { _ = try await client.transport.importJournal(batch); Issue.record("A viewing client must not publish remote history") }
      catch MobileConnectionError.http(let status, _) { #expect(status == 400 || status == 403) }
    }
    #expect(try await fixture.database.companionJournal(after: 0).entries.isEmpty)
    await #expect(throws: CompanionAPIError.self) {
      try await fixture.database.ingestCompanionJournal(batch, deviceID: identity.hostDeviceID)
    }

    // No observing client participates: the workspace's scoped publisher reaches
    // the real central API. Replaying its lost acknowledgement is idempotent.
    let request = CompanionHTTPRequest(method: "POST", target: "/wovenmatter/v1/federation/publisher/journal", headers: [
      "authorization": "Bearer " + grant.token, "x-woven-workspace": fixture.libraryID,
      "x-woven-protocol": String(CompanionProtocol.version)
    ], body: try JSONEncoder().encode(batch))
    let published = await fixture.api.handle(request)
    #expect(published.status == 200)
    let replay = await fixture.api.handle(request)
    #expect(replay.status == 200)
    #expect(try await fixture.database.companionJournal(after: 0).entries == entries)
    #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversationID)?.messages == [message])
    for client in [phone, mac] {
      try await MobileSyncEngine(store: client.store, transport: client.transport).synchronize()
      #expect(await client.store.snapshot().transcripts[conversationID]?.messages == [message])
    }
    #expect(fixture.commands.executions == 0)
    #expect(await source.submissions == 0)
    try await fixture.authentication.revoke(deviceID: phone.credential.deviceID)
    do { _ = try await phone.transport.libraryIdentity(); Issue.record("Revoked pairing must not read federation data") }
    catch MobileConnectionError.http(let status, _) { #expect(status == 401) }
    #expect(await phone.store.snapshot().transcripts[conversationID]?.messages == [message])
  }

  @Test("saved artifact transfer resumes after lost chunk acknowledgement and retains exact bytes on another client")
  func interruptedSavedArtifactTransfer() async throws {
    let fixture = try await FederationFlowFixture()
    defer { fixture.remove() }
    let owner = try await fixture.client("artifact-owner")
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: fixture.libraryID,
      ownerDeviceID: owner.credential.deviceID, kind: .ios, name: "This iPad")
    try await owner.store.journal.upsertWorkspace(workspace)
    let bytes = Data((0..<(2 * 1_024 * 1_024 + 731)).map { UInt8(truncatingIfNeeded: $0) })
    let manifest = try await owner.store.artifacts.save(data: bytes, workspaceID: workspace.id,
      title: "Saved output.bin", mediaType: "application/octet-stream")
    owner.transport.dropNextArtifactChunkAcknowledgement = true
    do {
      try await MobileSyncEngine(store: owner.store, transport: owner.transport).synchronize()
      Issue.record("Expected a committed chunk with a lost reply")
    } catch MobileConnectionError.offline {}
    #expect(try await owner.transport.artifactStatus(manifest.id).nextOffset == Int64(CompanionFederationProtocol.maximumArtifactChunkBytes))
    #expect(try await owner.transport.artifactManifests().isEmpty)
    let restarted = try MobileStore(file: owner.file)
    let local = try #require(await restarted.artifacts.localURL(id: manifest.id))
    #expect(try Data(contentsOf: local) == bytes)
    try await MobileSyncEngine(store: restarted, transport: owner.transport).synchronize()
    let reader = try await fixture.client("artifact-reader")
    try await MobileSyncEngine(store: reader.store, transport: reader.transport).synchronize()
    #expect(await reader.store.artifacts.localURL(id: manifest.id) == nil)
    let downloaded = try await reader.store.artifacts.download(id: manifest.id, using: reader.transport)
    #expect(try Data(contentsOf: downloaded) == bytes)
    let reopenedReader = try MobileStore(file: reader.file)
    #expect(await reopenedReader.artifacts.localURL(id: manifest.id) != nil)
    #expect(await reader.store.artifacts.manifests().count == 1)
    #expect(fixture.commands.executions == 0)
  }
}

@MainActor
private final class FederationFlowFixture {
  struct Client {
    let file: URL
    let store: MobileStore
    let credential: MobileCredential
    let transport: FederationAPITransport
  }
  let directory: URL
  let database: WorkspaceDatabase
  let authentication: CompanionAuthentication
  let commands = RejectExecutionCommands()
  let api: CompanionWorkspaceAPI
  let libraryID: String
  init() async throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "woven-federation-flow-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try await WorkspaceDatabase(url: directory.appending(path: "central.sqlite"))
    libraryID = try await database.companionWorkspaceID()
    authentication = try CompanionAuthentication(fileURL: directory.appending(path: "paired-devices.json"))
    api = CompanionWorkspaceAPI(database: database, authentication: authentication, commands: commands, isActive: { true })
  }
  func client(_ name: String) async throws -> Client {
    let file = directory.appending(path: name + "/library.json")
    let store = try MobileStore(file: file)
    let endpoint = URL(string: "https://central.test-tailnet.ts.net/wovenmatter")!
    let offer = try await authentication.createOffer(endpoint: endpoint)
    let request = CompanionPairRequest(token: offer.payload.token, deviceID: await store.snapshot().deviceID, deviceName: name)
    let response = await api.handle(.init(method: "POST", target: "/wovenmatter/v1/pair", headers: [:], body: try JSONEncoder().encode(request)))
    #expect(response.status == 200)
    let paired = try JSONDecoder().decode(CompanionPairResponse.self, from: response.body)
    let credential = MobileCredential(endpoint: endpoint, workspaceID: paired.workspaceID, deviceID: paired.deviceID, token: paired.credential)
    try await store.apply(CompanionSnapshot(workspaceID: libraryID, cursor: 0))
    return Client(file: file, store: store, credential: credential, transport: .init(api: api, credential: credential))
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Uses the production authenticated API, only replacing network I/O. Every
/// request crosses JSON encoding/decoding and the ordinary pairing credential.
@MainActor
private final class FederationAPITransport: CompanionTransport, FederationTransport {
  var api: CompanionWorkspaceAPI
  let credential: MobileCredential
  var canonicalLibraryID: String?
  var relocationID: String?
  func libraryRelocationID() async -> String? { relocationID }
  var dropNextJournalAcknowledgement = false
  var dropNextArtifactChunkAcknowledgement = false
  var journalImports = 0
  init(api: CompanionWorkspaceAPI, credential: MobileCredential) { self.api = api; self.credential = credential }
  private func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data = Data()) async throws -> T {
    var request = CompanionHTTPRequest(method: method, target: "/wovenmatter" + path, headers: [
      "authorization": "Bearer " + credential.token,
      "x-woven-workspace": credential.workspaceID,
      "x-woven-protocol": String(CompanionProtocol.version)
    ], body: body)
    if let canonicalLibraryID { request = try LibraryTransferRouting.request(request, from: credential.workspaceID, to: canonicalLibraryID) }
    var response = await api.handle(request)
    if let canonicalLibraryID { response = try LibraryTransferRouting.response(response, from: canonicalLibraryID, to: credential.workspaceID) }
    guard response.status == 200 else {
      let error = try JSONDecoder().decode(CompanionAPIError.self, from: response.body)
      throw MobileConnectionError.http(response.status, error.message)
    }
    return try JSONDecoder().decode(T.self, from: response.body)
  }
  func workspaceIdentity() async throws -> String { let hello: CompanionHello = try await request("/v1/hello"); return hello.workspaceID }
  func snapshot() async throws -> CompanionSnapshot { try await request("/v1/snapshot") }
  func changes(after: Int64) async throws -> CompanionChangePage { try await request("/v1/changes?after=\(after)") }
  func mutate(_ value: CompanionMutation) async throws -> CompanionMutationResult { try await request("/v1/mutations", method: "POST", body: JSONEncoder().encode(value)) }
  func note(_ id: String) async throws -> CompanionNote { try await request("/v1/notes/\(id)") }
  func providers() async throws -> [CompanionProvider] { try await request("/v1/providers") }
  func pending() async throws -> [CompanionPendingInteraction] { try await request("/v1/pending") }
  func transcript(_ id: String) async throws -> CompanionTranscript { try await request("/v1/sessions/\(id)/transcript") }
  func command(_ value: CompanionCommand) async throws -> CompanionCommandReceipt { try await request("/v1/commands", method: "POST", body: JSONEncoder().encode(value)) }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { throw MobileConnectionError.offline }
  func libraryIdentity() async throws -> CompanionLibraryIdentity { try await request("/v1/federation/identity") }
  func executionWorkspaces() async throws -> [CompanionExecutionWorkspace] { try await request("/v1/federation/workspaces") }
  func registerWorkspace(_ value: CompanionWorkspaceRegistration) async throws -> CompanionExecutionWorkspace { try await request("/v1/federation/workspaces", method: "POST", body: JSONEncoder().encode(value)) }
  func journal(after: Int64) async throws -> CompanionJournalPage { try await request("/v1/federation/journal?after=\(after)") }
  func importJournal(_ value: CompanionJournalBatch) async throws -> CompanionJournalBatchResult {
    journalImports += 1
    let result: CompanionJournalBatchResult = try await request("/v1/federation/journal", method: "POST", body: JSONEncoder().encode(value))
    if dropNextJournalAcknowledgement { dropNextJournalAcknowledgement = false; throw MobileConnectionError.offline }
    return result
  }
  func artifactManifests() async throws -> [CompanionArtifactManifest] { try await request("/v1/federation/artifacts") }
  func registerArtifact(_ value: CompanionArtifactRegistration) async throws -> CompanionArtifactTransfer { try await request("/v1/federation/artifacts/register", method: "POST", body: JSONEncoder().encode(value)) }
  func artifactStatus(_ id: String) async throws -> CompanionArtifactTransfer { try await request("/v1/federation/artifacts/\(id)") }
  func uploadArtifactChunk(_ value: CompanionArtifactChunk) async throws -> CompanionArtifactTransfer {
    let result: CompanionArtifactTransfer = try await request("/v1/federation/artifacts/chunk", method: "POST", body: JSONEncoder().encode(value))
    if dropNextArtifactChunkAcknowledgement { dropNextArtifactChunkAcknowledgement = false; throw MobileConnectionError.offline }
    return result
  }
  func commitArtifact(_ value: CompanionArtifactCommit) async throws -> CompanionArtifactManifest { try await request("/v1/federation/artifacts/commit", method: "POST", body: JSONEncoder().encode(value)) }
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) async throws -> CompanionArtifactChunk { try await request("/v1/federation/artifacts/\(id)/chunk?revision=\(revision)&offset=\(offset)") }
}

private actor RecordedExecutionSource: ExecutionWorkspaceTransport {
  let workspace: CompanionExecutionWorkspace
  let entries: [CompanionJournalEntry]
  private(set) var submissions = 0
  init(workspace: CompanionExecutionWorkspace, entries: [CompanionJournalEntry]) { self.workspace = workspace; self.entries = entries }
  func identity() -> CompanionExecutionWorkspace { workspace }
  func providers() -> [CompanionProvider] { [] }
  func pending() -> [CompanionPendingInteraction] { [] }
  func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt { submissions += 1; throw MobileConnectionError.offline }
  func receipt(_ id: String) -> CompanionCommandReceipt? { nil }
  func events(after: Int64) -> CompanionJournalPage {
    let page = Array(entries.filter { $0.originSequence > after }.prefix(200))
    let cursor = page.last?.originSequence ?? after
    return .init(libraryID: workspace.libraryID, cursor: cursor, entries: page, hasMore: cursor < Int64(entries.count))
  }
  func conversations() -> [CompanionConversation] { entries.compactMap(\.conversation) }
  func transcript(_ id: String) throws -> CompanionTranscript { guard let value = entries.compactMap(\.transcript).last(where: { $0.conversationID == id }) else { throw MobileConnectionError.offline }; return value }
}

@MainActor
private final class RejectExecutionCommands: CompanionCommandServing {
  private(set) var executions = 0
  func providers() -> [CompanionProvider] { [] }
  func pendingInteractions() -> [CompanionPendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) throws -> CompanionProvider { throw MobileConnectionError.offline }
  func transcript(conversationID: String, before: String?) throws -> CompanionTranscript { throw MobileConnectionError.offline }
  func receipt(commandID: String, deviceID: String) -> CompanionCommandReceipt? { nil }
  func execute(_ command: CompanionCommand, deviceID: String) throws -> CompanionCommandReceipt {
    executions += 1
    Issue.record("History synchronization must never execute an agent command")
    throw MobileConnectionError.offline
  }
}
