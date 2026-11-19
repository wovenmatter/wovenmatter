import XCTest
import UIKit
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

private actor MembershipLibrary: OfflineLibraryTransport {
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
    case "/wovenmatter/execution": body = try JSONEncoder().encode(workspace)
    case "/wovenmatter/execution/events": body = try JSONEncoder().encode(ExecutionJournalPage(libraryID: workspace.libraryID, cursor: 0))
    case "/wovenmatter/execution/providers":
      body = try JSONEncoder().encode([HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", routeName: workspace.name, available: true)])
    default: body = Data("[]".utf8)
    }
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

/// Every Mac and Linux machine after its pairings were cleared: each signed
/// request is answered "not a member".
private final class ForgetfulHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var requestCount: Int { lock.withLock { count } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { count += 1 }
    let body = try JSONEncoder().encode(LibraryAPIError(code: "unauthorized", message: MemberRequestError.unknown.message))
    return (body, HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

final class MembershipTests: XCTestCase {
  /// A Mac that clears its pairings no longer lists this phone. The phone
  /// learns that at its next sync: it stops asking, says it is no longer
  /// paired, and offers pairing again. Nothing it holds is touched, whether
  /// it then pairs again or forgets the pairing.
  @MainActor func testAPhoneItsMacNoLongerListsStopsSyncingAndOffersPairingAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let note = try await store.createNote(folderID: nil, title: "Mine", content: try NoteDocument(blocks: [.richText(.init(text: "Kept"))]).encoded())
    let model = MobileModel(store: store, transport: MembershipLibrary())
    model.executionDirectory = root.appendingPathComponent("execution", isDirectory: true)
    await model.reload()
    let studio = "a0000000-0000-0000-0000-00000000000a", endpoint = URL(string: "https://studio.tail1.ts.net/wovenmatter")!
    model.credential = .init(endpoint: endpoint, workspaceID: "library-a", deviceID: model.state.deviceID, token: "synthetic-test-token")
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-a", ownerDeviceID: studio, kind: .mac, name: "Studio",
      endpoint: endpoint, capabilities: [ExecutionWorkspace.libraryHistoryCapability], executionDeviceID: studio)
    try await store.journal.bind(libraryID: "library-a")
    try await store.journal.upsertWorkspace(workspace, pending: false, trustedRegistry: true)

    let http = ForgetfulHTTP()
    model.httpPerformer = http
    model.memberKeyStorage = .memory()
    let identity = try model.loadMemberIdentity()
    var membership = MobileMembershipState(deviceID: model.state.deviceID, pairedEndpoint: endpoint, pairedHostDeviceID: studio, pairedName: "Studio")
    membership.members = [.init(deviceID: studio, kind: "mac", name: "Studio", endpoints: [endpoint])]
    membership.currentHost = .init(deviceID: studio, kind: "mac", name: "Studio", endpoint: endpoint)
    let hosts = try MobileLibraryHosts(state: membership, identity: identity, file: nil, performer: http)
    let initial = try HTTPSLibraryTransport(host: endpoint, hostDeviceID: studio, identity: identity, performer: http)
    model.libraryHosts = hosts; model.membership = membership
    model.transport = initial
    model.engine = MobileSyncEngine(store: store, hosts: hosts, initial: initial)
    XCTAssertFalse(model.needsMemberPairing)
    XCTAssertNil(model.membershipNotice)

    await model.refresh()
    XCTAssertEqual(model.membership?.memberRejected, true)
    XCTAssertTrue(model.needsMemberPairing)
    XCTAssertNil(model.engine); XCTAssertNil(model.transport); XCTAssertFalse(model.online)
    XCTAssertNotNil(model.credential, "The pairing is still held, so the app offers Pair again and not a first pairing")
    let noun = model.deviceNoun
    XCTAssertEqual(model.membershipNotice,
                   "This \(noun) is no longer paired, so it isn’t syncing with your Macs and Linux machines. Pair again with any Mac. Your notes and chats stay on this \(noun).")
    XCTAssertTrue(model.launcherGroups.allSatisfy { $0.id == "local" }, "Home lists no workspace, so it shows the Pair again row")

    // It asks no machine again: not for the library, and not for a workspace.
    let asked = http.requestCount
    XCTAssertGreaterThan(asked, 0)
    await model.refresh()
    await model.refreshExecutionWorkspaces(force: true)
    XCTAssertEqual(http.requestCount, asked)
    XCTAssertTrue(model.workspaceClients.isEmpty)

    // Everything it holds is as it was, waiting for the next pairing.
    var state = await store.snapshot()
    XCTAssertEqual(state.workspaceID, "library-a")
    XCTAssertEqual(state.notes[note.id]?.title, "Mine")
    XCTAssertEqual(state.outbox.map(\.mutation.resourceID), [note.id])

    // Forgetting the pairing keeps it too: only the library binding is set aside.
    await model.disconnectMac(clearCredential: {})
    XCTAssertNil(model.credential); XCTAssertNil(model.membership); XCTAssertFalse(model.needsMemberPairing)
    state = await store.snapshot()
    XCTAssertNil(state.workspaceID); XCTAssertEqual(state.detachedWorkspaceID, "library-a")
    XCTAssertEqual(state.notes[note.id]?.title, "Mine")
    XCTAssertEqual(state.outbox.map(\.mutation.resourceID), [note.id])
    // Pairing with the same library again binds it back with nothing moved.
    try await store.prepareForPairing("library-a")
    state = await store.snapshot()
    XCTAssertEqual(state.workspaceID, "library-a"); XCTAssertNil(state.detachedWorkspaceID)
    XCTAssertEqual(state.notes[note.id]?.title, "Mine")
    XCTAssertEqual(state.outbox.map(\.mutation.resourceID), [note.id])
  }


  /// Every name for this device comes from one noun, so iPad never reads
  /// "iPhone" and a name mid-sentence never reads "this iphone".
  @MainActor func testDeviceIsNamedByItsOwnIdiomAtSentenceStartAndMidSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let model = MobileModel(store: store, transport: MembershipLibrary())
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

  /// The phone reaches another Mac's workspace with signed
  /// requests and no execution grant, and "host" is the host it syncs with.
  @MainActor func testThePhoneReachesWorkspacesWithSignaturesAndTheHostRouteFollowsTheHost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let model = MobileModel(store: store, transport: MembershipLibrary())
    await model.reload()
    XCTAssertNil(model.membershipNotice)
    model.credential = .init(endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, workspaceID: "library-a",
                             deviceID: model.state.deviceID, token: "synthetic-test-token")
    XCTAssertTrue(model.needsMemberPairing)
    XCTAssertNotNil(model.membershipNotice, "A paired phone that is not a member is asked to pair again")

    let mini = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-b", ownerDeviceID: "b0000000-0000-0000-0000-00000000000b",
      kind: .mac, name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!, capabilities: ["history.library"],
      executionDeviceID: "b0000000-0000-0000-0000-00000000000b")
    let studio = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library-a", ownerDeviceID: "a0000000-0000-0000-0000-00000000000a",
      kind: .mac, name: "Studio", endpoint: nil, capabilities: ["history.library"], executionDeviceID: "a0000000-0000-0000-0000-00000000000a")
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
