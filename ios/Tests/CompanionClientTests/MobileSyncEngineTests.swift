import XCTest
@testable import CompanionClient
import WovenMatterCompanion

private actor FakeMac: CompanionTransport {
  var workspace = "mac-a"
  var notes: [String: CompanionNote] = [:]
  var folders: [String: CompanionFolder] = [:]
  var mutations: [CompanionMutation] = []
  var results: [String: CompanionMutationResult] = [:]
  var commands: [CompanionCommand] = []
  var commandRequests: [CompanionCommand] = []
  var gatedReceiptID: String?
  var receiptGate: CheckedContinuation<Void, Never>?
  var receiptWaiting = false
  var hiddenReceipts: Set<String> = []
  var linked: CompanionLinkedData?
  func gateReceipt(_ id: String, hide: String) { gatedReceiptID = id; hiddenReceipts.insert(hide) }
  func releaseReceipt() { receiptGate?.resume(); receiptGate = nil }
  func setLinked(_ value: CompanionLinkedData) { linked = value }
  func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData {
    guard let linked else { throw MobileConnectionError.http(503, "Remote database data is unavailable on this Mac.") }
    return linked
  }
  var receipts: [String: CompanionCommandReceipt] = [:]
  var loseMutationAcknowledgement = false
  var loseCommandAcknowledgement = false
  var cursor: Int64 = 0
  func configure(workspace: String? = nil, loseMutation: Bool = false, loseCommand: Bool = false) {
    if let workspace { self.workspace = workspace }
    loseMutationAcknowledgement = loseMutation; loseCommandAcknowledgement = loseCommand
  }
  func workspaceIdentity() async throws -> String { workspace }
  func snapshot() async throws -> CompanionSnapshot { .init(workspaceID: workspace, cursor: cursor, folders: Array(folders.values), notes: Array(notes.values)) }
  func changes(after: Int64) async throws -> CompanionChangePage { .init(workspaceID: workspace, cursor: cursor) }
  func note(_ id: String) async throws -> CompanionNote { guard let note = notes[id] else { throw MobileConnectionError.http(404, "Deleted") }; return note }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult {
    mutations.append(mutation)
    if let result = results[mutation.operationID] { return result }
    let result: CompanionMutationResult
    if mutation.kind == .createFolder {
      let folder = CompanionFolder(id: mutation.resourceID, name: mutation.title!, revision: 1)
      folders[folder.id] = folder; result = .init(operationID: mutation.operationID, status: .accepted, folder: folder)
    } else {
      if let folder = mutation.folderID, folders[folder] == nil { return .init(operationID: mutation.operationID, status: .invalid, message: "Folder dependency missing") }
      let note = CompanionNote(id: mutation.resourceID, folderID: mutation.folderID, title: mutation.title!, content: mutation.content!, revision: (notes[mutation.resourceID]?.revision ?? 0) + 1)
      notes[note.id] = note
      var metadata = note; metadata.content = ""; metadata.contentIncluded = false
      result = .init(operationID: mutation.operationID, status: .accepted, note: metadata)
    }
    cursor += 1; results[mutation.operationID] = result
    if loseMutationAcknowledgement { loseMutationAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return result
  }
  func providers() async throws -> [CompanionProvider] {
    ["codex", "claude", "grok", "hermes", "cursor", "opencode", "pi", "openclaw"].map { .init(id: "local:" + $0, runtimeKind: $0, displayName: $0, available: true, canSteer: $0 == "codex") }
  }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { .init(conversationID: id, activeRunID: "mac-run") }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    commandRequests.append(command)
    if let receipt = receipts[command.commandID] { return receipt }
    commands.append(command)
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID, runID: "mac-run")
    receipts[command.commandID] = receipt
    if loseCommandAcknowledgement { loseCommandAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return receipt
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
    let captured = hiddenReceipts.contains(id) ? nil : receipts[id]
    if gatedReceiptID == id { gatedReceiptID = nil; receiptWaiting = true; await withCheckedContinuation { receiptGate = $0 } }
    return captured
  }
}

final class MobileSyncEngineTests: XCTestCase {
  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

  func testRepairedWorkspaceCannotReceiveExistingOutboxOrCommand() async throws {
    let store = try MobileStore(file: file())
    try await store.apply(CompanionSnapshot(workspaceID: "mac-a", cursor: 0))
    _ = try await store.createNote(folderID: nil, title: "Private to A", content: content("writing"))
    let mac = FakeMac(); await mac.configure(workspace: "mac-b")
    let engine = MobileSyncEngine(store: store, transport: mac)
    do { try await engine.synchronize(); XCTFail("Sent to different workspace") } catch MobileStore.Failure.wrongWorkspace {}
    do { _ = try await engine.submit(.init(deviceID: "phone", kind: .createSession, text: "Private to A")); XCTFail("Sent command to different workspace") } catch MobileStore.Failure.wrongWorkspace {}
    let mutationCount = await mac.mutations.count; let commandCount = await mac.commands.count
    XCTAssertEqual(mutationCount, 0); XCTAssertEqual(commandCount, 0)
    let local = await store.snapshot()
    XCTAssertEqual(local.outbox.count, 1)
  }

  func testLostMutationAcknowledgementRestartCreatesExactlyOneNote() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let folder = try await store.createFolder(name: "Ideas")
    let note = try await store.createNote(folderID: folder.id, title: "A thought", content: content("phone idea"))
    let mac = FakeMac(); await mac.configure(loseMutation: true)
    let engine = MobileSyncEngine(store: store, transport: mac)
    do { try await engine.synchronize(); XCTFail("Expected lost acknowledgement") } catch is URLError {}
    let restarted = try MobileStore(file: url)
    let recovered = MobileSyncEngine(store: restarted, transport: mac)
    try await recovered.synchronize()
    let canonical = await mac.notes
    XCTAssertEqual(canonical.count, 1); XCTAssertEqual(canonical[note.id]?.content, try content("phone idea"))
    let local = await restarted.snapshot()
    XCTAssertTrue(local.outbox.isEmpty); XCTAssertEqual(local.notes[note.id]?.content, canonical[note.id]?.content)
    let mutations = await mac.mutations
    XCTAssertEqual(mutations[0].operationID, mutations[1].operationID)
    XCTAssertEqual(mutations.last?.folderID, folder.id)
  }

  func testLostCommandAckRecoversReceiptWithoutSubmittingAgain() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let mac = FakeMac(); await mac.configure(loseCommand: true)
    let engine = MobileSyncEngine(store: store, transport: mac)
    try await engine.synchronize()
    let command = CompanionCommand(deviceID: await store.snapshot().deviceID, kind: .createSession, conversationID: "session", text: "Start once")
    do { _ = try await engine.submit(command); XCTFail("Expected lost acknowledgement") } catch is URLError {}
    let restarted = try MobileStore(file: url)
    let recovered = MobileSyncEngine(store: restarted, transport: mac)
    try await recovered.recoverCommandReceipts()
    let count = await mac.commands.count
    XCTAssertEqual(count, 1)
    let records = await restarted.snapshot().commands
    XCTAssertEqual(records.first?.receipt?.status, .completed)
    XCTAssertEqual(records.first?.receipt?.runID, "mac-run")
  }

  func testNoteReferenceIsFlushedAndBindsCanonicalRevision() async throws {
    let store = try MobileStore(file: file())
    let note = try await store.createNote(folderID: nil, title: "Idea", content: content("write first"))
    let mac = FakeMac(); let engine = MobileSyncEngine(store: store, transport: mac)
    _ = try await engine.submit(.init(deviceID: await store.snapshot().deviceID, kind: .createSession, conversationID: "session", text: "Use this", noteID: note.id))
    let command = await mac.commands.first
    XCTAssertEqual(command?.noteID, note.id); XCTAssertEqual(command?.noteRevision, 1)
    let canonicalContent = await mac.notes[note.id]?.content
    XCTAssertEqual(canonicalContent, try content("write first"))
  }
  private func awaitValue<T>(_ value: T) -> T { value }

  func testAllEightProviderDifferencesArePreserved() async throws {
    let mac = FakeMac(); let engine = MobileSyncEngine(store: try MobileStore(file: file()), transport: mac)
    let providers = try await engine.providers()
    XCTAssertEqual(providers.count, 8)
    XCTAssertEqual(providers.filter(\.canSteer).map(\.runtimeKind), ["codex"])
  }

  func testMetadataOnlyChangeCannotReplaceCachedBodyAtSameRevision() async throws {
    let store = try MobileStore(file: file())
    let original = CompanionNote(id: "note", title: "Plan", content: try content("keep body"), revision: 7)
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: [original]))
    var metadata = original; metadata.content = ""; metadata.contentIncluded = false
    try await store.apply(.init(workspaceID: "mac", cursor: 2, notes: [metadata]))
    var local = await store.snapshot()
    XCTAssertEqual(local.notes[original.id]?.content, original.content)
    metadata.revision = 8
    try await store.apply(.init(workspaceID: "mac", cursor: 3, notes: [metadata]))
    local = await store.snapshot()
    XCTAssertTrue(local.uncachedNoteIDs.contains(original.id))
    XCTAssertEqual(local.notes[original.id]?.title, "Plan")
  }
  func testNewChatDurableCreateThenExactPromptRunsOnceAfterLostAck() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let note = try await store.createNote(folderID: nil, title: "Referenced", content: content("idea"))
    let mac = FakeMac(); await mac.configure(loseCommand: true)
    let engine = MobileSyncEngine(store: store, transport: mac)
    let create = CompanionCommand(deviceID: "phone", kind: .createSession, conversationID: "new-conversation", providerID: "local:codex")
    let send = CompanionCommand(deviceID: "phone", kind: .send, conversationID: create.conversationID, text: "The exact first prompt", noteID: note.id)
    let launch = MobileLaunchRecord(create: create, initialSend: send)
    do { _ = try await engine.startConversation(launch); XCTFail("Expected lost create acknowledgement") } catch is URLError {}
    let restarted = try MobileStore(file: url)
    let recovered = MobileSyncEngine(store: restarted, transport: mac)
    try await recovered.recoverCommandReceipts()
    var accepted = await mac.commands
    XCTAssertEqual(accepted.count, 1, "Reconnect must not silently execute the unsent initial prompt")
    await mac.configure(loseCommand: true)
    do { _ = try await recovered.startConversation(launch); XCTFail("Expected lost send acknowledgement") } catch is URLError {}
    try await recovered.recoverCommandReceipts()
    let final = try await recovered.startConversation(launch)
    XCTAssertTrue(final.accepted)
    accepted = await mac.commands
    XCTAssertEqual(accepted.count, 2)
    XCTAssertEqual(accepted.filter { $0.kind == .createSession }.count, 1)
    XCTAssertEqual(accepted.filter { $0.kind == .send }.count, 1)
    XCTAssertEqual(accepted.last?.text, "The exact first prompt")
    XCTAssertEqual(accepted.last?.noteID, note.id)
    XCTAssertEqual(accepted.last?.noteRevision, 1)
    XCTAssertNil(accepted.first?.text)
  }

  func testRetryKeepsOriginalNoteRevisionWhenLocalNoteChangesAfterLostAck() async throws {
    let store = try MobileStore(file: file())
    let note = try await store.createNote(folderID: nil, title: "Plan", content: content("first version"))
    let mac = FakeMac(); await mac.configure(loseCommand: true)
    let engine = MobileSyncEngine(store: store, transport: mac)
    let command = CompanionCommand(deviceID: "phone", kind: .send, conversationID: "session", text: "Read this exact revision", noteID: note.id)
    do { _ = try await engine.submit(command); XCTFail("Expected dropped acknowledgement") } catch is URLError {}
    try await store.editNote(id: note.id, title: "Plan", content: content("new local version"), folderID: nil)
    let result = try await engine.submit(command)
    XCTAssertEqual(result.status, .completed)
    let accepted = await mac.commands
    XCTAssertEqual(accepted.count, 1)
    XCTAssertEqual(accepted[0].noteRevision, 1)
    let local = await store.snapshot()
    XCTAssertTrue(local.isDirty(note.id))
    XCTAssertEqual(local.commands.first?.command.noteRevision, 1)
  }

  func testLateCreateReceiptRecoveryCannotOverwritePreparedInitialSend() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let note = try await store.createNote(folderID: nil, title: "Referenced", content: content("original"))
    let mac = FakeMac(); await mac.configure(loseCommand: true)
    let engine = MobileSyncEngine(store: store, transport: mac)
    let create = CompanionCommand(deviceID: "phone", kind: .createSession, conversationID: "new", providerID: "local:codex")
    let send = CompanionCommand(deviceID: "phone", kind: .send, conversationID: "new", text: "Exact prompt", noteID: note.id)
    let launch = MobileLaunchRecord(create: create, initialSend: send)
    do { _ = try await engine.startConversation(launch); XCTFail("Expected lost create ACK") } catch is URLError {}
    await mac.gateReceipt(create.commandID, hide: send.commandID)
    let recovery = Task { try await engine.recoverCommandReceipts() }
    for _ in 0..<100 { if await mac.receiptWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
    let waiting = await mac.receiptWaiting; XCTAssertTrue(waiting)
    await mac.configure(loseCommand: true)
    do { _ = try await engine.startConversation(launch); XCTFail("Expected lost send ACK") } catch is URLError {}
    let prepared = await store.snapshot().launches.first!
    XCTAssertTrue(prepared.sendPrepared); XCTAssertEqual(prepared.initialSend.noteRevision, 1)
    await mac.releaseReceipt(); try await recovery.value
    let recovered = try MobileStore(file: url)
    let retained = await recovered.snapshot().launches.first!
    XCTAssertTrue(retained.sendPrepared); XCTAssertEqual(retained.initialSend, prepared.initialSend)
    try await recovered.editNote(id: note.id, title: "Referenced", content: content("changed after restart"), folderID: nil)
    let restarted = MobileSyncEngine(store: recovered, transport: mac)
    _ = try await restarted.startConversation(launch)
    let attempts = await mac.commandRequests.filter { $0.kind == .send }
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[0], attempts[1], "Same command ID must always have exactly the same bytes and note revision")
  }

  func testLinkedDataRequiresMatchingDocumentRevisionAndPreservesUnavailableReason() async throws {
    let store = try MobileStore(file: file()); let mac = FakeMac()
    let engine = MobileSyncEngine(store: store, transport: mac)
    let note = CompanionNote(id: "asset", title: "Chart", content: "", revision: 2)
    do { _ = try await engine.linkedData(note: note); XCTFail() }
    catch { XCTAssertTrue(error.localizedDescription.contains("Remote database data is unavailable")) }
    await mac.setLinked(.init(noteID: note.id, noteRevision: 3, columns: ["Name"], rows: [["current"]], json: "[]"))
    do { _ = try await engine.linkedData(note: note); XCTFail("Accepted stale note preview") }
    catch MobileConnectionError.http(409, _) {}
    await mac.setLinked(.init(noteID: note.id, noteRevision: 2, columns: ["Name"], rows: [["exact"]], json: "[]"))
    let preview = try await engine.linkedData(note: note)
    XCTAssertEqual(preview.rows, [["exact"]])
    let local = await store.snapshot()
    XCTAssertTrue(local.outbox.isEmpty); XCTAssertTrue(local.notes.isEmpty)
  }

}
