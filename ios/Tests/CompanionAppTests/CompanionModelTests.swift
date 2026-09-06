import XCTest
import SwiftUI
import CompanionClient
import WovenMatterCompanion
@testable import WovenMatterMobileApp

private actor ModelMac: CompanionTransport {
  var commands: [CompanionCommand] = []
  var gate: CheckedContinuation<Void, Never>?
  var shouldGate = true
  var waiting = false
  func workspaceIdentity() async throws -> String {
    if shouldGate { waiting = true; await withCheckedContinuation { gate = $0 } }
    return "workspace"
  }
  func release() { shouldGate = false; gate?.resume(); gate = nil }
  func snapshot() async throws -> CompanionSnapshot { .init(workspaceID: "workspace", cursor: 1) }
  func changes(after: Int64) async throws -> CompanionChangePage { .init(workspaceID: "workspace", cursor: 1) }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult { throw MobileConnectionError.offline }
  func note(_ id: String) async throws -> CompanionNote { throw MobileConnectionError.offline }
  func providers() async throws -> [CompanionProvider] { [] }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { .init(conversationID: id) }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    commands.append(command)
    return .init(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { nil }
}

final class CompanionModelTests: XCTestCase {
  @MainActor func testAppHostedUnitTestsOpenOnlyAnIsolatedLibraryWithoutNetworking() async throws {
    let model = CompanionModel()
    XCTAssertTrue(model.isolatedTestHost)
    await model.run()
    XCTAssertNil(model.credential)
    XCTAssertFalse(model.online)
    XCTAssertTrue(model.state.notes.isEmpty)
    let store = try XCTUnwrap(model.store)
    let snapshot = await store.snapshot()
    XCTAssertNil(snapshot.workspaceID)
    XCTAssertTrue(snapshot.notes.isEmpty)
  }

  @MainActor func testSwitchingConversationDuringSendDoesNotRedirectOrClearOtherDraft() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    try await store.apply(CompanionSnapshot(workspaceID: "workspace", cursor: 1, conversations: [
      .init(id: "A", title: "Conversation A"), .init(id: "B", title: "Conversation B")]))
    let mac = ModelMac(); let model = CompanionModel(store: store, transport: mac)
    await model.reload()
    model.selectedConversationID = "A"; model.composer = "Prompt for A"
    let sending = Task { await model.send() }
    for _ in 0..<100 {
      if await mac.waiting { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let waiting = await mac.waiting
    XCTAssertTrue(waiting)
    model.selectedConversationID = "B"; model.composer = "Draft for B"
    await mac.release(); await sending.value
    XCTAssertEqual(model.selectedConversationID, "B")
    XCTAssertEqual(model.composer, "Draft for B")
    let commands = await mac.commands
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].conversationID, "A")
    XCTAssertEqual(commands[0].text, "Prompt for A")
    await model.flushLocalWrites()
    let restarted = try MobileStore(file: file)
    let drafts = await restarted.snapshot().chatDrafts
    XCTAssertEqual(drafts["A"]?.text, "")
    XCTAssertEqual(drafts["B"]?.text, "Draft for B")
  }
  @MainActor func testRemoteTitleAndBodyAdoptionDoesNotCreateSyntheticEdit() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    let original = CompanionNote(id: "note", title: "Before", content: try NoteDocument(blocks: [.richText(.init(text: "before"))]).encoded())
    try await store.apply(.init(workspaceID: "workspace", cursor: 1, notes: [original]))
    let model = CompanionModel(store: store, transport: ModelMac())
    await model.reload(); model.selectedNoteID = original.id
    var remote = original; remote.title = "After"; remote.content = try NoteDocument(blocks: [.richText(.init(text: "after"))]).encoded(); remote.revision = 2
    try await store.apply(.init(workspaceID: "workspace", cursor: 2, notes: [remote]))
    await model.reload(); await model.flushLocalWrites()
    XCTAssertEqual(model.selectedNote, remote)
    let state = await store.snapshot()
    XCTAssertTrue(state.outbox.isEmpty)
    XCTAssertTrue(model.draftContents.isEmpty)
  }
  @MainActor func testContinueDoesNotStealNavigationOrClearNewReference() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    try await store.apply(CompanionSnapshot(workspaceID: "workspace", cursor: 1))
    let mac = ModelMac(); let model = CompanionModel(store: store, transport: mac)
    await model.reload(); model.tab = .home; model.composer = "Exact prompt"; model.providerID = "local:codex"
    let launch = MobileLaunchRecord(create: .init(deviceID: "phone", kind: .createSession, conversationID: "created", providerID: "local:codex"),
      initialSend: .init(deviceID: "phone", kind: .send, conversationID: "created", text: "Exact prompt"))
    let continuing = Task { await model.continueLaunch(launch) }
    for _ in 0..<100 { if await mac.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
    let waiting = await mac.waiting; XCTAssertTrue(waiting)
    model.tab = .folders; model.referencedNoteID = "new-reference"; model.providerID = "local:claude"
    await mac.release(); await continuing.value
    XCTAssertEqual(model.tab, .folders)
    XCTAssertNil(model.selectedConversationID)
    XCTAssertEqual(model.composer, "Exact prompt")
    XCTAssertEqual(model.referencedNoteID, "new-reference")
    await model.flushLocalWrites()
    let reopened = try MobileStore(file: file)
    let draft = await reopened.snapshot().chatDrafts["new-chat"]
    XCTAssertEqual(draft?.noteID, "new-reference")
  }

  @MainActor func testRenderedNotePaneAdoptsRemoteBodyWithoutSavingSyntheticEdit() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    let original = CompanionNote(id: "rendered-note", title: "Original title", content: try NoteDocument(blocks: [.richText(.init(id: "body", text: "Original body"))]).encoded(), revision: 1)
    try await store.apply(.init(workspaceID: "workspace", cursor: 1, notes: [original]))
    let model = CompanionModel(store: store, transport: ModelMac())
    await model.reload(); model.selectedNoteID = original.id
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: RenderedNoteHost(model: model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    for _ in 0..<100 { if visibleTextViews(window).contains("Original body") { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(visibleTextViews(window).contains("Original body"))
    var remote = original; remote.title = "Remote title"; remote.content = try NoteDocument(blocks: [.richText(.init(id: "body", text: "Remote body"))]).encoded(); remote.revision = 2
    try await store.apply(.init(workspaceID: "workspace", cursor: 2, notes: [remote]))
    await model.reload()
    for _ in 0..<100 { if visibleTextViews(window).contains("Remote body") { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(visibleTextViews(window).contains("Remote body"))
    await model.flushLocalWrites()
    let local = await store.snapshot()
    XCTAssertTrue(local.outbox.isEmpty)
    XCTAssertEqual(local.notes[remote.id], remote)
    XCTAssertTrue(model.draftContents.isEmpty)
  }
  @MainActor private func visibleTextViews(_ view: UIView) -> [String] {
    (view as? UITextView).map { [$0.text ?? ""] } ?? view.subviews.flatMap { visibleTextViews($0) }
  }

}

private struct RenderedNoteHost: View {
  @Bindable var model: CompanionModel
  var body: some View { if let note = model.selectedNote { NotePane(model: model, note: note) } }
}
