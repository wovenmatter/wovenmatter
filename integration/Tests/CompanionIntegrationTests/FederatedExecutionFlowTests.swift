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

  @Test("two authorized observers relay one workspace history, while an ungranted client cannot")
  func observerRelayAndOriginAuthorization() async throws {
    let fixture = try await FederationFlowFixture()
    defer { fixture.remove() }
    let owner = try await fixture.client("owner")
    let phone = try await fixture.client("observer-phone")
    let mac = try await fixture.client("observer-mac")
    let outsider = try await fixture.client("ungranted")
    var workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: fixture.libraryID,
      ownerDeviceID: owner.credential.deviceID, kind: .linux, name: "Linux",
      journalDeviceIDs: [phone.credential.deviceID, mac.credential.deviceID])
    workspace = try await owner.transport.registerWorkspace(.init(workspace: workspace))
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
    let source = RecordedExecutionSource(workspace: workspace, entries: entries)
    for client in [phone, mac, outsider] {
      try await WorkspaceClient(store: client.store, workspaceID: workspace.id, transport: source).refresh()
      #expect(await client.store.snapshot().transcripts[conversationID]?.messages == [message])
      #expect(await client.store.journal.snapshot().pendingEventIDs.count == 2)
    }
    do {
      try await MobileSyncEngine(store: outsider.store, transport: outsider.transport).synchronize()
      Issue.record("An ungranted client must not publish workspace history")
    } catch MobileConnectionError.http(let status, _) { #expect(status == 400 || status == 403) }
    #expect(await outsider.store.journal.snapshot().pendingEventIDs.count == 2)
    #expect(try await fixture.database.companionJournal(after: 0).entries.isEmpty)

    for client in [phone, mac] {
      try await MobileSyncEngine(store: client.store, transport: client.transport).synchronize()
      #expect(await client.store.journal.snapshot().pendingEventIDs.isEmpty)
    }
    #expect(try await fixture.database.companionJournal(after: 0).entries == entries)
    #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversationID)?.messages == [message])
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
    let downloaded = try #require(await reader.store.artifacts.localURL(id: manifest.id))
    #expect(try Data(contentsOf: downloaded) == bytes)
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
  let api: CompanionWorkspaceAPI
  let credential: MobileCredential
  var dropNextJournalAcknowledgement = false
  var dropNextArtifactChunkAcknowledgement = false
  var journalImports = 0
  init(api: CompanionWorkspaceAPI, credential: MobileCredential) { self.api = api; self.credential = credential }
  private func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data = Data()) async throws -> T {
    let response = await api.handle(.init(method: method, target: "/wovenmatter" + path, headers: [
      "authorization": "Bearer " + credential.token,
      "x-woven-workspace": credential.workspaceID,
      "x-woven-protocol": String(CompanionProtocol.version)
    ], body: body))
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
