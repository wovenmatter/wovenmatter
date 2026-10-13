import XCTest
import UIKit
import CompanionClient
import WovenMatterCompanion
@testable import WovenMatterMobileApp

private actor PairingSettingsMac: CompanionTransport {
  var waitForProviders = false
  var providerRequestWaiting = false
  var providerGate: CheckedContinuation<Void, Never>?
  func holdProviders() { waitForProviders = true }
  func releaseProviders() { waitForProviders = false; providerGate?.resume(); providerGate = nil }
  func workspaceIdentity() async throws -> String { "library-a" }
  func snapshot() async throws -> CompanionSnapshot { .init(workspaceID: "library-a", cursor: 1) }
  func changes(after: Int64) async throws -> CompanionChangePage { .init(workspaceID: "library-a", cursor: 1) }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult { throw MobileConnectionError.offline }
  func note(_ id: String) async throws -> CompanionNote { throw MobileConnectionError.offline }
  func providers() async throws -> [CompanionProvider] {
    if waitForProviders { providerRequestWaiting = true; await withCheckedContinuation { providerGate = $0 } }
    return []
  }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { .init(conversationID: id) }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { throw MobileConnectionError.offline }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { nil }
}

private actor DisabledPairingWorkspace: ExecutionWorkspaceTransport {
  func identity() async throws -> CompanionExecutionWorkspace { throw MobileConnectionError.revoked }
  func providers() async throws -> [CompanionProvider] { throw MobileConnectionError.revoked }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { throw MobileConnectionError.revoked }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { nil }
  func events(after: Int64) async throws -> CompanionJournalPage { throw MobileConnectionError.revoked }
  func conversations() async throws -> [CompanionConversation] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { throw MobileConnectionError.revoked }
}

final class PairingSettingsTests: XCTestCase {
  @MainActor func testDisconnectPreservesPendingWritingLibraryBindingAndDirectWorkspaceAvailability() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    _ = try await store.createNote(folderID: nil, title: "Offline writing", content: "Saved locally")
    let model = CompanionModel(store: store, transport: PairingSettingsMac())
    await model.reload()
    model.workspaceReachable["linux-workspace"] = true
    let before = await store.snapshot()
    var cleared = false
    await model.disconnectMac { cleared = true }
    XCTAssertTrue(cleared)
    XCTAssertNil(model.credential); XCTAssertNil(model.engine); XCTAssertFalse(model.online)
    XCTAssertEqual(model.workspaceReachable["linux-workspace"], true)
    let after = await store.snapshot()
    XCTAssertEqual(after, before)
    XCTAssertGreaterThan(model.pendingSyncCount, 0)
    let reopened = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let persisted = await reopened.snapshot()
    XCTAssertEqual(persisted.workspaceID, "library-a")
    XCTAssertEqual(persisted.outbox, before.outbox)
    var savedWrongCredential = false
    let wrong = MobileCredential(endpoint: URL(string: "https://other-mac.example.ts.net/wovenmatter")!,
      workspaceID: "library-b", deviceID: before.deviceID, token: "synthetic-test-token")
    do { try await model.acceptPairing(wrong) { _ in savedWrongCredential = true }; XCTFail("Mixed two libraries") }
    catch MobileStore.Failure.wrongWorkspace { }
    XCTAssertFalse(savedWrongCredential)
    let final = await store.snapshot(); XCTAssertEqual(final, before)
  }

  @MainActor func testDisabledWorkspaceDiscardsOnlyItsGrantAndRemainsDimmed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: PairingSettingsMac())
    await model.reload()
    let workspace = CompanionExecutionWorkspace(id: "disabled", libraryID: "library-a", ownerDeviceID: "mac", kind: .mac, name: "Other Mac")
    model.executionWorkspaces = [workspace]
    model.workspaceClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: DisabledPairingWorkspace())
    model.workspaceReachable[workspace.id] = true
    model.workspaceProviders[workspace.id] = [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)]
    var cleared: [String] = []
    await model.refreshDirectWorkspace(workspace.id) { cleared.append($0) }
    XCTAssertEqual(cleared, [workspace.id])
    XCTAssertNil(model.workspaceClients[workspace.id])
    XCTAssertEqual(model.workspaceReachable[workspace.id], false)
    XCTAssertFalse(try XCTUnwrap(model.launcherAgents.first { $0.workspaceID == workspace.id }).isAvailable)
    XCTAssertTrue(model.online)
    XCTAssertNotNil(model.engine)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor func testFirstPairingBindsLibraryBeforeAnyNetworkSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: PairingSettingsMac())
    await model.reload()
    let paired = MobileCredential(endpoint: URL(string: "https://central.example.ts.net/wovenmatter")!,
      workspaceID: "library-a", deviceID: model.state.deviceID, token: "synthetic-test-token")
    var saved: MobileCredential?
    try await model.acceptPairing(paired) { saved = $0 }
    XCTAssertEqual(saved, paired)
    XCTAssertEqual(model.state.workspaceID, "library-a")
    XCTAssertFalse(model.online)
    await model.disconnectMac { }
    let reopened = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let persisted = await reopened.snapshot()
    XCTAssertEqual(persisted.workspaceID, "library-a")
    XCTAssertEqual(persisted.cursor, 0)
  }

  @MainActor func testLateRefreshCannotReconnectModelAfterDisconnect() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let mac = PairingSettingsMac(); await mac.holdProviders()
    let model = CompanionModel(store: store, transport: mac)
    let refresh = Task { await model.refresh() }
    for _ in 0..<200 {
      if await mac.providerRequestWaiting { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let waiting = await mac.providerRequestWaiting; XCTAssertTrue(waiting)
    await model.disconnectMac { }
    await mac.releaseProviders(); await refresh.value
    XCTAssertNil(model.engine); XCTAssertFalse(model.online)
    XCTAssertEqual(model.connectionLabel, "Disconnected")
    XCTAssertTrue(model.pending.isEmpty)
  }

  @MainActor func testUnpairedNotesNeverClaimCentralSyncAndDeviceMetadataIsExplicit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: PairingSettingsMac())
    await model.reload()
    XCTAssertEqual(model.saveLabel("unpaired"), "Saved on this device")
    XCTAssertEqual(model.deviceMetadata.kind, UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone)
    XCTAssertEqual(model.deviceMetadata.osVersion, UIDevice.current.systemVersion)
    XCTAssertEqual(CompanionModel.connectionRetryDelay(1), 5)
    XCTAssertEqual(CompanionModel.connectionRetryDelay(20), 120)
  }
}
