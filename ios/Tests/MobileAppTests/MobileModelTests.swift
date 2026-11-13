import XCTest
import SwiftUI
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

/// Offline central-library defaults shared by the app test transports.
protocol OfflineLibraryTransport: LibraryTransport {}
extension OfflineLibraryTransport {
  func workspaceIdentity() async throws -> String { throw MobileConnectionError.offline }
  func snapshot() async throws -> LibrarySnapshot { throw MobileConnectionError.offline }
  func changes(after: Int64) async throws -> LibraryChangePage { throw MobileConnectionError.offline }
  func mutate(_ mutation: LibraryMutation) async throws -> LibraryMutationResult { throw MobileConnectionError.offline }
  func note(_ id: String) async throws -> LibraryNote { throw MobileConnectionError.offline }
  func providers() async throws -> [HarnessCapabilities] { throw MobileConnectionError.offline }
  func pending() async throws -> [PendingInteraction] { throw MobileConnectionError.offline }
  func transcript(_ id: String) async throws -> LibraryTranscript { throw MobileConnectionError.offline }
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt { throw MobileConnectionError.offline }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { throw MobileConnectionError.offline }
}

private actor ModelMac: OfflineLibraryTransport, LibraryCalendarTransport {
  var calendarRecords: [String: LibraryCalendarRecord] = [:]
  var calendarReceipts: [String: LibraryCalendarReceipt] = [:]
  var calendarRequests: [LibraryCalendarMutation] = []
  var dropNextCalendarReply = false
  func loseNextCalendarReply() { dropNextCalendarReply = true }
  func calendarSnapshot() async throws -> LibraryCalendarSnapshot { .init(workspaceID: "workspace", records: Array(calendarRecords.values)) }
  func calendarPublishRuns(_ runs: [LibraryCalendarRun]) async throws -> [String] { runs.map(\.id) }
  func calendarMutate(_ mutation: LibraryCalendarMutation) async throws -> LibraryCalendarReceipt {
    calendarRequests.append(mutation)
    if let receipt = calendarReceipts[mutation.id] { return receipt }
    var record = mutation.record; record.event.revision = mutation.expectedRevision.map { $0 + 1 } ?? 0
    calendarRecords[record.id] = record
    let receipt = LibraryCalendarReceipt(mutationID: mutation.id, status: .accepted, record: record)
    calendarReceipts[mutation.id] = receipt
    if dropNextCalendarReply { dropNextCalendarReply = false; throw MobileConnectionError.offline }
    return receipt
  }
  var commands: [LibraryCommand] = []
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
  func snapshot() async throws -> LibrarySnapshot { .init(workspaceID: "workspace", cursor: 1) }
  func changes(after: Int64) async throws -> LibraryChangePage { .init(workspaceID: "workspace", cursor: 1) }
  func providers() async throws -> [HarnessCapabilities] { [] }
  func pending() async throws -> [PendingInteraction] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { .init(conversationID: id) }
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    commands.append(command)
    if dropNextCommand { dropNextCommand = false; throw MobileConnectionError.offline }
    return .init(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
  }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { nil }
}

final class MobileModelTests: XCTestCase {
  /// A lost reply leaves change A with an unknown outcome. A is kept with its
  /// command ID; a different change to the same item waits, an unrelated item
  /// proceeds, and repeating A resends the original command rather than a new one.
  @MainActor func testUnknownWorkspaceChangeOrdersOnlyItsOwnItemAndRetryKeepsItsIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mac = ModelMac(); await mac.release()
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let model = MobileModel(store: store, transport: mac)
    model.online = true
    let renameA = LibraryWorkspaceAction.conversation(id: "chat-a", action: "rename", title: "A", folderID: nil)
    await mac.loseNextReply()
    let lost = await model.perform(renameA)
    XCTAssertFalse(lost)
    let recorded = await store.snapshot().commands.first { $0.command.workspaceAction == renameA }
    let unknown = try XCTUnwrap(recorded)
    XCTAssertNil(unknown.receipt, "The unconfirmed change is kept, not discarded or marked done")

    let renameB = await model.perform(.conversation(id: "chat-b", action: "rename", title: "B", folderID: nil))
    XCTAssertTrue(renameB, "An unrelated item is not blocked by A")
    let moveA = await model.perform(.conversation(id: "chat-a", action: "move", title: nil, folderID: "folder"))
    XCTAssertFalse(moveA, "A later change to the same item waits for A")
    XCTAssertNotNil(model.errorMessage)

    let retried = await model.perform(renameA)
    XCTAssertTrue(retried)
    let commands = await mac.commands
    XCTAssertEqual(commands.filter { $0.workspaceAction == renameA }.map(\.commandID), [unknown.id, unknown.id], "Retry resends the original command identity")
    XCTAssertFalse(commands.contains { $0.workspaceAction == .conversation(id: "chat-a", action: "move", title: nil, folderID: "folder") })
    let saved = await store.snapshot().commands.first { $0.id == unknown.id }
    XCTAssertEqual(saved?.receipt?.status, .completed)
  }

  /// A phone that was never paired keeps everything on the device: a note is
  /// deleted there (pairing later never sees it), and analytics have nowhere
  /// to go. Once paired, notes go to the library's Trash instead.
  @MainActor func testStandaloneNotesDeleteOnThisDeviceAndAnalyticsHaveNoDestination() async throws {
    let model = MobileModel()
    XCTAssertTrue(model.isStandalone)
    let analyticsTarget = await model.analyticsTransport()
    XCTAssertNil(analyticsTarget)
    await model.newNote()
    let id = try XCTUnwrap(model.selectedNoteID)
    let created = try XCTUnwrap(model.state.notes[id])
    model.saveNote(id: id, title: "Packing", content: created.content, base: created)
    await model.flushLocalWrites()
    let deleted = await model.deleteLocalNote(id)
    XCTAssertTrue(deleted)
    XCTAssertNil(model.state.notes[id]); XCTAssertNil(model.selectedNoteID)
    XCTAssertTrue(model.state.outbox.isEmpty, "Pairing later never uploads a deleted local note")

    await model.newNote()
    let kept = try XCTUnwrap(model.selectedNoteID)
    try await XCTUnwrap(model.store).bindWorkspace("library")
    await model.reload()
    XCTAssertFalse(model.isStandalone)
    let refused = await model.deleteLocalNote(kept)
    XCTAssertFalse(refused)
    XCTAssertNotNil(model.state.notes[kept])

    // After unpairing, even a note created later may already be in a library.
    try await XCTUnwrap(model.store).detachWorkspace()
    await model.reload()
    XCTAssertTrue(model.isStandalone)
    await model.newNote()
    let afterUnpair = try XCTUnwrap(model.selectedNoteID)
    XCTAssertFalse(model.canDeleteNoteLocally(afterUnpair))
    XCTAssertFalse(model.canDeleteNoteLocally(kept))
  }

  @MainActor func testWorkspaceGroupingMatchesPrefixedFolderBindingsWithoutChangingRoute() {
    let model = MobileModel()
    let registryID = UUID().uuidString.lowercased()
    let mac = ExecutionWorkspace(id: registryID, libraryID: "library", ownerDeviceID: registryID, kind: .mac, name: "Mac", capabilities: ["history.central.v1"], executionDeviceID: registryID)
    model.executionWorkspaces = [mac]; model.workspaceReachable[registryID] = true
    let folder = LibraryFolder(id: "project", name: "Project", execution: .init(workspaceID: "device:" + registryID.uppercased(), rootPath: "/project"))
    let chat = LibraryConversation(id: "chat", title: "Chat", providerID: "pi", workspaceID: registryID)
    model.state.folders[folder.id] = folder; model.state.conversations[chat.id] = chat
    XCTAssertEqual(model.folderWorkspaceGroups.count, 2)
    XCTAssertEqual(model.folderOwner(folder), registryID)
    XCTAssertEqual(model.conversationOwner(chat), registryID)
    XCTAssertEqual(model.executionOwner(of: chat.id), registryID, "Execution requests must retain the registered route identity")
    XCTAssertTrue(model.routeOwnsFolder(workspaceID: "central", folderID: folder.id))
    model.openFolder(folder.id)
    XCTAssertEqual(model.selectedFolderWorkspaceID, registryID)
  }

  /// The central Mac's registry id and host device id are generated apart from
  /// the `device:<device id>` its existing folders are bound to.
  @MainActor func testCentralMacFoldersGroupUnderItsWorkspaceThroughPublishedFolderOwner() {
    let model = MobileModel()
    let registryID = UUID().uuidString.lowercased(), hostDeviceID = UUID().uuidString.lowercased()
    let folderOwner = "device:" + UUID().uuidString.lowercased()
    var mac = ExecutionWorkspace(id: registryID, libraryID: "library", ownerDeviceID: hostDeviceID, kind: .mac, name: "Mac Mini",
                                          capabilities: ["history.central.v1"], executionDeviceID: hostDeviceID)
    let folder = LibraryFolder(id: "launch", name: "Launch research", execution: .init(workspaceID: folderOwner, rootPath: "/tmp/Launch"))
    let note = LibraryNote(id: "pilot", folderID: folder.id, title: "Pilot checklist", content: "")
    model.state.folders[folder.id] = folder; model.state.notes[note.id] = note
    model.executionWorkspaces = [mac]; model.workspaceReachable[registryID] = true
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [model.canonicalWorkspaceID(model.deviceWorkspaceID), registryID])
    XCTAssertNotEqual(model.folderOwner(folder), registryID, "A Mac that does not name its folder owner leaves them in All Workspaces only")
    XCTAssertFalse(model.folderWorkspaceGroups.contains { $0.name == "Unavailable workspace" })

    mac.folderOwnerID = folderOwner
    model.executionWorkspaces = [mac]
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [model.canonicalWorkspaceID(model.deviceWorkspaceID), registryID])
    XCTAssertFalse(model.folderWorkspaceGroups.contains { $0.name == "Unavailable workspace" })
    XCTAssertEqual(model.folderOwner(folder), registryID)
    XCTAssertEqual(model.noteOwner(note), registryID)
    XCTAssertTrue(model.routeOwnsFolder(workspaceID: registryID, folderID: folder.id), "The Mac's agents may start chats in its folders")
    XCTAssertEqual(model.workspaceRoute(for: folderOwner), registryID)
    XCTAssertEqual(model.state.folders[folder.id]?.execution?.workspaceID, folderOwner, "Stored bindings are not rewritten")
  }

  /// A saved registry row and cached agent catalog never list a workspace:
  /// Home, Folders, New Chat and Calendar show Quick Chat plus the paired
  /// workspaces reachable now, and a workspace comes back by itself once a
  /// refresh reaches it. Nothing stored is removed.
  @MainActor func testOnlyReachableWorkspacesAreListedAndReappearWhenReachable() {
    let model = MobileModel()
    let macID = UUID().uuidString.lowercased(), linuxID = UUID().uuidString.lowercased()
    let mac = ExecutionWorkspace(id: macID, libraryID: "library", ownerDeviceID: macID, kind: .mac, name: "James's MacBook Air",
                                          capabilities: ["history.central.v1"], executionDeviceID: macID)
    let linux = ExecutionWorkspace(id: linuxID, libraryID: "library", ownerDeviceID: macID, kind: .linux, name: "Build server")
    model.executionWorkspaces = [mac, linux]
    let ready = HarnessCapabilities(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)
    let notReady = HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: false, canStart: false)
    // The saved catalog from an earlier connection.
    model.providers = [ready, notReady]
    model.workspaceProviders = [macID: [ready, notReady], linuxID: [.init(id: "pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)]]
    model.knownAgentIDs = ["central:local:codex", macID + ":local:codex", linuxID + ":pi"]
    let orphan = LibraryFolder(id: "orphan", name: "Old Mac folder", execution: .init(workspaceID: "device:" + UUID().uuidString.lowercased(), rootPath: "/old"))
    let linuxFolder = LibraryFolder(id: "linux-folder", name: "Releases", execution: .init(workspaceID: "remote:" + linuxID, rootPath: "/srv"))
    model.state.folders = [orphan.id: orphan, linuxFolder.id: linuxFolder]
    let local = model.canonicalWorkspaceID(model.deviceWorkspaceID)

    XCTAssertEqual(model.launcherGroups.map(\.id), ["local"], "Cached workspaces are not listed as if connected")
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [local])
    XCTAssertFalse(model.folderWorkspaceGroups.contains { $0.name == "Unavailable workspace" })
    XCTAssertEqual(model.chatLauncherGroups.map(\.id), ["local"])
    XCTAssertEqual(model.listedLauncherAgents.map(\.workspaceID), ["local"])
    XCTAssertFalse(model.workspaceIsActive(mac)); XCTAssertFalse(model.workspaceIsActive(linux))
    XCTAssertEqual(model.state.folders.count, 2, "Nothing stored is removed")
    model.openFolder(nil)
    XCTAssertTrue(model.folderScopeIncludes(owner: model.folderOwner(orphan), folderID: nil), "Unlisted owners' folders stay in All Workspaces")

    // A direct refresh reaches the Linux workspace: it reappears with its folders.
    model.workspaceReachable[linuxID] = true
    XCTAssertEqual(model.launcherGroups.map(\.id), ["local", linuxID], "Quick Chat leads")
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [local, linuxID])
    XCTAssertEqual(model.folderOwner(linuxFolder), linuxID)
    XCTAssertEqual(model.chatLauncherGroups.map(\.id), ["local", linuxID])
    model.workspaceReachable[linuxID] = false
    XCTAssertEqual(model.launcherGroups.map(\.id), ["local"], "A workspace that stops answering is no longer listed")

    // The library host this phone syncs with is reachable; its agents that are
    // not ready there are listed dimmed rather than hidden.
    model.online = true
    let central = try? XCTUnwrap(model.launcherGroups.first { $0.id == "central" })
    XCTAssertEqual(central?.name, mac.name)
    XCTAssertEqual(central?.agents.map(\.name), ["Pi Durable", "Codex"])
    XCTAssertEqual(central?.agents.map(\.isAvailable), [true, false])
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [local, macID])
    XCTAssertFalse(model.launcherGroups.contains { $0.id == linuxID })
    model.online = false
    XCTAssertEqual(model.launcherGroups.map(\.id), ["local"])

    // A copied snapshot owner is history only, even when its copied endpoint answers.
    let copiedID = UUID().uuidString.lowercased()
    var copied = ExecutionWorkspace(id: copiedID, libraryID: "library", ownerDeviceID: copiedID, kind: .mac, name: "James's MacBook Air",
                                             capabilities: ["history.central.v1"], executionDeviceID: copiedID)
    copied.retainedHistory = true
    var copiedPhone = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone")
    copiedPhone.retainedHistory = true
    model.executionWorkspaces = [mac, linux, copied, copiedPhone]
    model.workspaceProviders[copiedID] = [ready, notReady]
    model.workspaceReachable[copiedID] = true
    XCTAssertFalse(model.workspaceIsActive(copied))
    XCTAssertEqual(model.launcherGroups.map(\.id), ["local"])
    XCTAssertEqual(model.chatLauncherGroups.map(\.id), ["local"])
    XCTAssertFalse(model.listedLauncherAgents.contains { $0.workspaceID == copiedID })
    XCTAssertEqual(model.folderWorkspaceGroups.map(\.id), [local])
    model.online = true
    XCTAssertEqual(model.launcherGroups.first { $0.id == "central" }?.workspace?.id, macID, "The live Mac, not the copy, is the central workspace")
    XCTAssertFalse(model.launcherGroups.contains { $0.id == copiedID })
  }

  @MainActor func testRecentsCompareActualTimesAcrossFractionalSecondsAndOffsets() {
    let model = MobileModel()
    model.state.notes["fraction"] = .init(id: "fraction", title: "Fraction", content: "", updatedAt: "2026-10-30T10:00:00.500Z")
    model.state.notes["whole"] = .init(id: "whole", title: "Whole", content: "", updatedAt: "2026-10-30T10:00:00Z")
    model.state.conversations["offset"] = .init(id: "offset", title: "Offset", updatedAt: "2026-10-30T07:00:01-03:00")
    XCTAssertEqual(model.folderRecentItems.map(\.resourceID), ["offset", "fraction", "whole"])
  }

  @MainActor func testUnpairedNoteRenameAndMovePersistWithoutCentralRequests() async throws {
    let model = MobileModel()
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
    XCTAssertTrue(saved.commands.isEmpty)
    XCTAssertEqual(saved.outbox.filter { $0.mutation.resourceID == note.id }.count, 1)
    XCTAssertEqual(saved.outbox.first { $0.mutation.resourceID == note.id }?.mutation.kind, .createNote)
  }

  @MainActor func testFolderRecentsMixNotesAndChatsByLatestActivityWithFourteenItemLimit() {
    let model = MobileModel()
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
    let model = MobileModel()
    let phone = model.state.deviceID
    let otherPhone = UUID().uuidString.lowercased()
    let local = LibraryFolder(id: UUID().uuidString, name: "Local", execution: .init(workspaceID: "device:" + phone, rootPath: "/local"))
    let foreign = LibraryFolder(id: UUID().uuidString, name: "Other phone", execution: .init(workspaceID: "device:" + otherPhone, rootPath: "/foreign"))
    model.state.folders = [local.id: local, foreign.id: foreign]
    model.executionWorkspaces = [.init(id: otherPhone, libraryID: "library", ownerDeviceID: otherPhone, kind: .ios, name: "My iPad")]
    let unknown = LibraryNote(id: UUID().uuidString, title: "Legacy", content: "")
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
    let model = MobileModel()
    let folder = try await XCTUnwrap(model.store).createFolder(name: "Previously opened")
    await model.reload()
    model.openFolder(folder.id)
    model.tab = .home
    await model.newNote()
    let note = try XCTUnwrap(model.selectedNote)
    XCTAssertNil(note.folderID)
  }

  @MainActor func testForeignQuickChatIsHistoryAndUnknownConversationStaysUnassigned() {
    let model = MobileModel()
    let owner = UUID().uuidString.lowercased()
    let chat = LibraryConversation(id: UUID().uuidString, title: "Phone chat", providerID: "pi-durable-device", workspaceID: owner)
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
    let model = MobileModel()
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
    try await store.apply(LibrarySnapshot(workspaceID: "workspace", cursor: 1, conversations: [
      .init(id: "A", title: "Conversation A"), .init(id: "B", title: "Conversation B")]))
    let mac = ModelMac(); let model = MobileModel(store: store, transport: mac)
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
    let model = MobileModel(store: store, transport: mac)
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
    try await store.apply(LibrarySnapshot(workspaceID: "workspace", cursor: 1))
    let mac = ModelMac(); await mac.release(); await mac.loseNextReply()
    let model = MobileModel(store: store, transport: mac)
    let action = LibraryWorkspaceAction.retryLibrary(id: "retained-file")
    let unrelatedAction = LibraryWorkspaceAction.retryLibrary(id: "unrelated")
    let first = await model.perform(action); XCTAssertFalse(first)
    // An unknown outcome waits only for its own item; another item proceeds with its own command.
    let unrelated = await model.perform(unrelatedAction); XCTAssertTrue(unrelated)
    let between = await store.snapshot().commands
    XCTAssertNil(between.first { $0.command.workspaceAction == action }?.receipt, "The original stays unresolved, not discarded or settled")
    XCTAssertEqual(between.first { $0.command.workspaceAction == unrelatedAction }?.receipt?.status, .completed)
    let second = await model.perform(action); XCTAssertTrue(second)
    let commands = await mac.commands
    XCTAssertEqual(commands.map(\.workspaceAction), [action, unrelatedAction, action], "Lost original, unrelated item, then the original's retry")
    let originals = commands.filter { $0.workspaceAction == action }, others = commands.filter { $0.workspaceAction == unrelatedAction }
    XCTAssertEqual(originals.count, 2)
    XCTAssertEqual(originals.first, originals.last, "The retry resends the identical command and payload")
    XCTAssertEqual(others.count, 1)
    XCTAssertNotEqual(others.first?.commandID, originals.first?.commandID)
    let snapshot = await store.snapshot()
    XCTAssertEqual(Set(snapshot.commands.map(\.id)), Set([originals.first?.commandID, others.first?.commandID].compactMap { $0 }),
                   "Both requests stay recorded; the lost one is not discarded or replaced")
    XCTAssertTrue(snapshot.commands.allSatisfy { $0.receipt?.status == .completed })
  }

  @MainActor func testRemoteTitleAndBodyAdoptionDoesNotCreateSyntheticEdit() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json")
    let store = try MobileStore(file: file)
    let original = LibraryNote(id: "note", title: "Before", content: try NoteDocument(blocks: [.richText(.init(text: "before"))]).encoded())
    try await store.apply(.init(workspaceID: "workspace", cursor: 1, notes: [original]))
    let model = MobileModel(store: store, transport: ModelMac())
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
    let original = LibraryNote(id: "rendered-note", title: "Original title", content: try NoteDocument(blocks: [.richText(.init(id: "body", text: "Original body"))]).encoded(), revision: 1)
    try await store.apply(.init(workspaceID: "workspace", cursor: 1, notes: [original]))
    let model = MobileModel(store: store, transport: ModelMac())
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
  @Bindable var model: MobileModel
  var body: some View { if let note = model.selectedNote { NotePane(model: model, note: note) } }
}
