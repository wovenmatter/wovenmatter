import XCTest
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

private actor MemberModeLibrary: OfflineLibraryTransport {
  func workspaceIdentity() async throws -> String { "library-a" }
  func snapshot() async throws -> LibrarySnapshot { .init(workspaceID: "library-a", cursor: 1) }
  func changes(after: Int64) async throws -> LibraryChangePage { .init(workspaceID: "library-a", cursor: 1) }
  func providers() async throws -> [LibraryProvider] { [] }
  func pending() async throws -> [PendingInteraction] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { .init(conversationID: id) }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { nil }
}

/// Answers a Mac's execution routes and records what the phone sent.
private final class SignedWorkspaceHTTP: MobileHTTPPerforming, @unchecked Sendable {
  let workspace: ExecutionWorkspace
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  init(workspace: ExecutionWorkspace) { self.workspace = workspace }
  var requests: [URLRequest] { lock.withLock { recorded } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    let path = request.url?.path ?? ""
    let body: Data
    switch path {
    case "/wovenmatter/v1/execution": body = try JSONEncoder().encode(workspace)
    case "/wovenmatter/v1/execution/events": body = try JSONEncoder().encode(LibraryJournalPage(libraryID: workspace.libraryID, cursor: 0))
    case "/wovenmatter/v1/execution/providers":
      body = try JSONEncoder().encode([LibraryProvider(id: "local:codex", runtimeKind: "codex", displayName: "Codex", routeName: workspace.name, available: true)])
    default: body = Data("[]".utf8)
    }
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

final class MemberModeTests: XCTestCase {
  /// In member mode the phone reaches another Mac's workspace with signed
  /// requests and no execution grant, and "central" is the host it syncs with.
  @MainActor func testMemberModeReachesWorkspacesWithSignaturesAndCentralFollowsTheHost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let model = MobileModel(store: store, transport: MemberModeLibrary())
    await model.reload()
    XCTAssertNil(model.membershipNotice)
    model.credential = .init(endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, workspaceID: "library-a",
                             deviceID: model.state.deviceID, token: "synthetic-test-token")
    XCTAssertTrue(model.needsMemberPairing)
    XCTAssertNotNil(model.membershipNotice, "A phone paired before members is asked to pair again once")

    let mini = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-b", ownerDeviceID: "b0000000-0000-0000-0000-00000000000b",
      kind: .mac, name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!, capabilities: ["execution.v1", "history.central.v1"],
      executionDeviceID: "b0000000-0000-0000-0000-00000000000b")
    let studio = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-a", ownerDeviceID: "a0000000-0000-0000-0000-00000000000a",
      kind: .mac, name: "Studio", endpoint: nil, capabilities: ["execution.v1", "history.central.v1"], executionDeviceID: "a0000000-0000-0000-0000-00000000000a")
    // As a synchronization does, bind the journal to the host's library first.
    try await store.journal.bind(libraryID: "library-a")
    try await store.journal.upsertWorkspace(mini, pending: false, trustedRegistry: true)
    try await store.journal.upsertWorkspace(studio, pending: false, trustedRegistry: true)

    let http = SignedWorkspaceHTTP(workspace: mini)
    model.httpPerformer = http
    model.memberKeyStorage = .memory()
    let identity = try model.loadMemberIdentity()
    var membership = MobileMembershipState(deviceID: model.state.deviceID, pairedEndpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!,
                                           pairedHostDeviceID: "a0000000-0000-0000-0000-00000000000a")
    membership.currentHost = .init(deviceID: "a0000000-0000-0000-0000-00000000000a", kind: "mac", name: "Studio", endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!)
    model.libraryHosts = try MobileLibraryHosts(state: membership, identity: identity, file: nil, performer: http)
    model.membership = membership
    XCTAssertFalse(model.needsMemberPairing)
    // No grant may be issued or read in member mode.
    model.workspaceCredentials = .init(load: { _ in XCTFail("Read a grant"); return nil }, save: { _ in XCTFail("Saved a grant") }, clear: { _ in })

    await model.refreshExecutionWorkspaces(force: true)
    await model.workspacePollTasks[mini.id]?.value
    XCTAssertEqual(model.workspaceReachable[mini.id], true, model.workspaceProblems[mini.id] ?? "")
    XCTAssertEqual(model.workspaceProviders[mini.id]?.map(\.id), ["local:codex"])
    XCTAssertFalse(http.requests.isEmpty)
    for request in http.requests {
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woven-Member-Device"), identity.deviceID)
      XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Woven-Member-Signature"))
    }
    // "Central" is the Mac this phone syncs with, not the first Mac listed.
    XCTAssertEqual(model.centralExecutionWorkspace?.id, studio.id)
    membership.currentHost = .init(deviceID: "b0000000-0000-0000-0000-00000000000b", kind: "mac", name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!)
    model.membership = membership
    XCTAssertEqual(model.centralExecutionWorkspace?.id, mini.id)
  }
}
