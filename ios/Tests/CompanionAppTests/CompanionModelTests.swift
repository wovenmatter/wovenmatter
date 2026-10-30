import XCTest
import SwiftUI
import CompanionClient
import WovenMatterCompanion
@testable import WovenMatterMobileApp

private actor ModelMac: CompanionTransport, CompanionCalendarTransport {
  var calendarRecords: [String: CompanionCalendarRecord] = [:]
  var calendarReceipts: [String: CompanionCalendarReceipt] = [:]
  var calendarRequests: [CompanionCalendarMutation] = []
  var dropNextCalendarReply = false
  func loseNextCalendarReply() { dropNextCalendarReply = true }
  func calendarSnapshot() async throws -> CompanionCalendarSnapshot { .init(workspaceID: "workspace", records: Array(calendarRecords.values)) }
  func calendarPublishRuns(_ runs: [CompanionCalendarRun]) async throws -> [String] { runs.map(\.id) }
  func calendarMutate(_ mutation: CompanionCalendarMutation) async throws -> CompanionCalendarReceipt {
    calendarRequests.append(mutation)
    if let receipt = calendarReceipts[mutation.id] { return receipt }
    var record = mutation.record; record.event.revision = mutation.expectedRevision.map { $0 + 1 } ?? 0
    calendarRecords[record.id] = record
    let receipt = CompanionCalendarReceipt(mutationID: mutation.id, status: .accepted, record: record)
    calendarReceipts[mutation.id] = receipt
    if dropNextCalendarReply { dropNextCalendarReply = false; throw MobileConnectionError.offline }
    return receipt
  }
  var commands: [CompanionCommand] = []
  var gate: CheckedContinuation<Void, Never>?
  var shouldGate = true
  var waiting = false
  var dropNextCommand = false
  func loseNextReply() { dropNextCommand = true }
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
    if dropNextCommand { dropNextCommand = false; throw MobileConnectionError.offline }
    return .init(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { nil }
}

final class CompanionModelTests: XCTestCase {
  @MainActor func testWorkspaceGroupingResolvesRegisteredMacContentIdentityWithoutChangingRoute() {
    let model = CompanionModel()
    let registryID = UUID().uuidString.lowercased(), hostID = UUID().uuidString.lowercased(), contentID = UUID().uuidString.lowercased()
    var mac = CompanionExecutionWorkspace(id: registryID, libraryID: "library", ownerDeviceID: hostID, kind: .mac, name: "Mac", capabilities: ["history.central.v1"], executionDeviceID: hostID)
    mac.contentWorkspaceID = "device:" + contentID
    model.executionWorkspaces = [mac]
    let folder = CompanionFolder(id: "project", name: "Project", execution: .init(workspaceID: "device:" + contentID, rootPath: "/project"))
    let chat = CompanionConversation(id: "chat", title: "Chat", providerID: "pi", workspaceID: registryID)
    model.state.folders[folder.id] = folder; model.state.conversations[chat.id] = chat
    XCTAssertEqual(model.folderWorkspaceGroups.count, 2)
    XCTAssertEqual(model.folderOwner(folder), contentID)
    XCTAssertEqual(model.conversationOwner(chat), contentID)
    XCTAssertEqual(model.executionOwner(of: chat.id), registryID, "Execution requests must retain the registered route identity")
    XCTAssertTrue(model.routeOwnsFolder(workspaceID: "central", folderID: folder.id))
    model.openFolder(folder.id)
    XCTAssertEqual(model.selectedFolderWorkspaceID, contentID)
  }

  @MainActor func testRecentsCompareActualTimesAcrossFractionalSecondsAndOffsets() {
    let model = CompanionModel()
    model.state.notes["fraction"] = .init(id: "fraction", title: "Fraction", content: "", updatedAt: "2026-10-30T10:00:00.500Z")
    model.state.notes["whole"] = .init(id: "whole", title: "Whole", content: "", updatedAt: "2026-10-30T10:00:00Z")
    model.state.conversations["offset"] = .init(id: "offset", title: "Offset", updatedAt: "2026-10-30T07:00:01-03:00")
    XCTAssertEqual(model.folderRecentItems.map(\.resourceID), ["offset", "fraction", "whole"])
  }

  @MainActor func testUnpairedNoteRenameAndMovePersistWithoutCentralRequests() async throws {
    let model = CompanionModel()
    let store = try XCTUnwrap(model.store)
    let note = try await store.createNote(folderID: nil, title: "Before", content: NoteDocument().encoded())
    let folder = try await store.createFolder(name: "Phone ideas")
    await model.reload()
    XCTAssertFalse(model.online)
    XCTAssertTrue(model.canEditNoteDetails(note.id))
    let renamed = await model.editNoteDetails(note.id, action: "rename", title: "After", folderID: nil)
    let moved = await model.editNoteDetails(note.id, action: "move", title: "Stale title", folderID: folder.id)
    XCTAssertTrue(renamed); XCTAssertTrue(moved)
    let saved = await store.snapshot()
    XCTAssertEqual(saved.notes[note.id]?.title, "After")
    XCTAssertEqual(saved.notes[note.id]?.folderID, folder.id)
    XCTAssertEqual(saved.notes[note.id]?.workspaceID, saved.deviceID)
    XCTAssertTrue(saved.commands.isEmpty)
    XCTAssertEqual(saved.outbox.filter { $0.mutation.resourceID == note.id }.count, 1)
    XCTAssertEqual(saved.outbox.first { $0.mutation.resourceID == note.id }?.mutation.kind, .createNote)
  }

  @MainActor func testFolderRecentsMixNotesAndChatsByLatestActivityWithFourteenItemLimit() {
    let model = CompanionModel()
    for index in 0..<20 {
      let id = "item-\(index)"
      let timestamp = "2026-10-30T10:00:" + String(format: "%02d", index) + "Z"
      if index.isMultiple(of: 2) {
        model.state.notes[id] = .init(id: id, title: "Note \(index)", content: "", updatedAt: timestamp, isPinned: index == 0)
      } else {
        model.state.conversations[id] = .init(id: id, title: "Chat \(index)", updatedAt: timestamp, isPinned: index == 1)
      }
    }
    let recents = model.folderRecentItems
    XCTAssertEqual(recents.count, 14)
    XCTAssertEqual(recents.first?.resourceID, "item-19")
    XCTAssertEqual(recents.last?.resourceID, "item-6")
    XCTAssertEqual(recents.filter(\.isNote).count, 7)
    XCTAssertFalse(recents.contains { $0.resourceID == "item-0" || $0.resourceID == "item-1" }, "Pinning must not replace recent activity ordering")
    model.state.notes["item-0"]?.updatedAt = "2026-10-30T11:00:00Z"
    XCTAssertEqual(model.folderRecentItems.first?.resourceID, "item-0", "Editing an old note brings it into mixed recents")
    XCTAssertEqual(model.folderRecentItems.count, 14)
  }

  @MainActor func testFolderGroupsDistinguishThisDeviceAndRetainUnknownOwnership() {
    let model = CompanionModel()
    let phone = model.state.deviceID
    let otherPhone = UUID().uuidString.lowercased()
    let local = CompanionFolder(id: UUID().uuidString, name: "Local", execution: .init(workspaceID: "device:" + phone, rootPath: "/local"))
    let foreign = CompanionFolder(id: UUID().uuidString, name: "Other phone", execution: .init(workspaceID: "device:" + otherPhone, rootPath: "/foreign"))
    model.state.folders = [local.id: local, foreign.id: foreign]
    model.executionWorkspaces = [.init(id: otherPhone, libraryID: "library", ownerDeviceID: otherPhone, kind: .ios, name: "My iPad")]
    let unknown = CompanionNote(id: UUID().uuidString, title: "Legacy", content: "")
    model.state.notes[unknown.id] = unknown
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [phone, otherPhone])
    XCTAssertTrue(model.routeOwnsFolder(workspaceID: "local", folderID: local.id))
    XCTAssertFalse(model.routeOwnsFolder(workspaceID: "local", folderID: foreign.id))
    XCTAssertNil(model.noteOwner(unknown))
    XCTAssertTrue(model.hasUnassignedContent)
    XCTAssertTrue(model.folderAgents(in: model.folderWorkspaceGroups[1]).isEmpty)
    model.openFolder(nil, workspaceID: phone, unfiled: true)
    XCTAssertTrue(model.folderScopeIncludes(owner: phone, folderID: nil))
    XCTAssertFalse(model.folderScopeIncludes(owner: otherPhone, folderID: nil))
    XCTAssertFalse(model.folderScopeIncludes(owner: phone, folderID: local.id))
    model.openFolder(nil)
    XCTAssertTrue(model.folderScopeIncludes(owner: otherPhone, folderID: foreign.id))
    XCTAssertTrue(model.folderScopeIncludes(owner: nil, folderID: nil))
  }

  @MainActor func testNewNoteFromHomeDoesNotInheritPreviouslyOpenedRemoteFolder() async throws {
    let model = CompanionModel()
    let folder = try await XCTUnwrap(model.store).createFolder(name: "Previously opened")
    await model.reload()
    model.openFolder(folder.id)
    model.tab = .home
    await model.newNote()
    let note = try XCTUnwrap(model.selectedNote)
    XCTAssertNil(note.folderID)
    XCTAssertEqual(note.workspaceID, model.state.deviceID)
  }

  @MainActor func testForeignQuickChatIsHistoryAndUnknownConversationStaysUnassigned() {
    let model = CompanionModel()
    let owner = UUID().uuidString.lowercased()
    let chat = CompanionConversation(id: UUID().uuidString, title: "Phone chat", providerID: "pi-durable-device", workspaceID: owner)
    model.state.conversations[chat.id] = chat
    model.selectedConversationID = chat.id
    XCTAssertTrue(model.isViewingRemoteQuickChat)
    XCTAssertEqual(model.conversationOwner(chat), owner)
    XCTAssertNil(model.conversationOwner(.init(id: "legacy", title: "Unknown")))
  }

  func testSharedIconLicenseIsIncludedInTheAppBundle() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "LUCIDE_LICENSE", withExtension: "txt"))
    let license = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(license.contains("Copyright (c) 2026 Lucide Icons and Contributors"))
    XCTAssertTrue(license.contains("Copyright (c) 2013-present Cole Bemis"))
  }

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
  @MainActor func testCalendarSavesOfflineAndSynchronizesOnceAfterLostReceipt() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try MobileStore(file: file)
    let mac = ModelMac(); await mac.release()
    let model = CompanionModel(store: store, transport: mac)
    model.online = false; await model.reload()
    let id = UUID().uuidString.lowercased(), start = Date(timeIntervalSince1970: 1_792_000_000)
    let saved = await model.perform(.saveCalendar(id: id, revision: nil, draft: .init(title: "Offline event", startsAt: start)))
    XCTAssertTrue(saved)
    guard case .calendar(let events) = try await model.workspace(.calendar(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1))) else { return XCTFail("Calendar was not local") }
    XCTAssertEqual(events.map(\.id), [id])
    let noRequests = await mac.calendarRequests; XCTAssertTrue(noRequests.isEmpty)
    let reopened = try MobileStore(file: file)
    let persisted = await reopened.calendar.records(); XCTAssertEqual(persisted.map(\.id), [id])
    await mac.loseNextCalendarReply()
    let engine = MobileSyncEngine(store: reopened, transport: mac)
    do { try await engine.synchronize(); XCTFail("Expected lost acknowledgement") } catch { }
    try await engine.synchronize()
    let requests = await mac.calendarRequests
    XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.first, requests.last)
    let remote = await mac.calendarRecords; XCTAssertEqual(remote.count, 1)
    let pending = await reopened.calendar.pendingCount(); XCTAssertEqual(pending, 0)
    let commands = await mac.commands; XCTAssertTrue(commands.isEmpty)
  }

  @MainActor func testWorkspaceRetryRetainsCommandIdentityAfterLostAcknowledgement() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    try await store.apply(CompanionSnapshot(workspaceID: "workspace", cursor: 1))
    let mac = ModelMac(); await mac.release(); await mac.loseNextReply()
    let model = CompanionModel(store: store, transport: mac)
    let action = CompanionWorkspaceAction.retryLibrary(id: "retained-file")
    let first = await model.perform(action); XCTAssertFalse(first)
    let different = await model.perform(.retryLibrary(id: "unrelated")); XCTAssertFalse(different)
    let second = await model.perform(action); XCTAssertTrue(second)
    let commands = await mac.commands
    XCTAssertEqual(commands.count, 2)
    XCTAssertEqual(commands.first, commands.last)
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.commands.count, 1)
    XCTAssertEqual(snapshot.commands.first?.receipt?.status, .completed)
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
