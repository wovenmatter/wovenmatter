import XCTest
import UIKit
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

private actor MemberModeLibrary: OfflineLibraryTransport {
  func workspaceIdentity() async throws -> String { "library-a" }
  func snapshot() async throws -> LibrarySnapshot { .init(workspaceID: "library-a", cursor: 1) }
  func changes(after: Int64) async throws -> LibraryChangePage { .init(workspaceID: "library-a", cursor: 1) }
  func providers() async throws -> [HarnessCapabilities] { [] }
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
    case "/wovenmatter/v1/execution/events": body = try JSONEncoder().encode(ExecutionJournalPage(libraryID: workspace.libraryID, cursor: 0))
    case "/wovenmatter/v1/execution/providers":
      body = try JSONEncoder().encode([HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", routeName: workspace.name, available: true)])
    default: body = Data("[]".utf8)
    }
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

final class MemberModeTests: XCTestCase {
  /// Every name for this device comes from one noun, so iPad never reads
  /// "iPhone" and a name mid-sentence never reads "this iphone".
  @MainActor func testDeviceIsNamedByItsOwnIdiomAtSentenceStartAndMidSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let model = MobileModel(store: store, transport: MemberModeLibrary())
    let noun = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    XCTAssertEqual(model.deviceNoun, noun)
    XCTAssertEqual(model.deviceWorkspaceName, "This " + noun)
    XCTAssertEqual(model.deviceWorkspaceInSentence, "this " + noun)
    XCTAssertEqual(model.deviceConnectionsTitle, noun + " Connections")

    model.credential = .init(endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, workspaceID: "library-a",
                             deviceID: model.state.deviceID, token: "synthetic-test-token")
    let notice = try XCTUnwrap(model.membershipNotice)
    XCTAssertTrue(notice.contains("so this \(noun) connects directly"), notice)
    XCTAssertTrue(notice.hasSuffix("stay on this \(noun)."), notice)
    let other = noun == "iPad" ? "iPhone" : "iPad"
    XCTAssertFalse(notice.contains(other), notice)
  }

  /// In member mode the phone reaches another Mac's workspace with signed
  /// requests and no execution grant, and "host" is the host it syncs with.
  @MainActor func testMemberModeReachesWorkspacesWithSignaturesAndTheHostRouteFollowsTheHost() async throws {
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
    XCTAssertNotNil(model.membershipNotice, "A paired phone that is not a member is asked to pair again")

    let mini = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-b", ownerDeviceID: "b0000000-0000-0000-0000-00000000000b",
      kind: .mac, name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!, capabilities: ["execution.v1", "history.library.v1"],
      executionDeviceID: "b0000000-0000-0000-0000-00000000000b")
    let studio = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-a", ownerDeviceID: "a0000000-0000-0000-0000-00000000000a",
      kind: .mac, name: "Studio", endpoint: nil, capabilities: ["execution.v1", "history.library.v1"], executionDeviceID: "a0000000-0000-0000-0000-00000000000a")
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

    await model.refreshExecutionWorkspaces(force: true)
    await model.workspaceReadTasks[mini.id]?.value
    XCTAssertEqual(model.workspaceReachable[mini.id], true, model.workspaceProblems[mini.id] ?? "")
    XCTAssertEqual(model.workspaceProviders[mini.id]?.map(\.id), ["local:codex"])
    XCTAssertFalse(http.requests.isEmpty)
    for request in http.requests {
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woven-Member-Device"), identity.deviceID)
      XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Woven-Member-Signature"))
    }
    // The host route is the Mac this phone syncs with, not the first Mac listed.
    XCTAssertEqual(model.hostExecutionWorkspace?.id, studio.id)
    membership.currentHost = .init(deviceID: "b0000000-0000-0000-0000-00000000000b", kind: "mac", name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!)
    model.membership = membership
    XCTAssertEqual(model.hostExecutionWorkspace?.id, mini.id)
  }
}
