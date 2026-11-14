import XCTest
import CryptoKit
@testable import LibraryClient
import WovenMatterShared

/// Records requests and answers them from a closure, standing in for Macs and
/// Linux hosts on the tailnet.
final class RecordingHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private let reply: @Sendable (URLRequest) throws -> (Int, Data)
  init(reply: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.reply = reply }
  var requests: [URLRequest] { lock.withLock { recorded } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    let (status, body) = try reply(request)
    return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

final class MemberReachTests: XCTestCase {
  let phoneID = UUID().uuidString.lowercased()

  func testMemberKeyIsStableForTheLibraryDeviceAndReplacedForAnother() throws {
    let storage = MobileMemberKeyStorage.memory()
    let first = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: storage)
    let again = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID.uppercased(), storage: storage)
    XCTAssertEqual(first.publicKey, again.publicKey, "A re-pair must present the same key")
    XCTAssertEqual(first.publicKey.count, 32)
    let other = try MobileMemberKeyVault.loadOrCreate(deviceID: UUID().uuidString.lowercased(), storage: storage)
    XCTAssertNotEqual(other.publicKey, first.publicKey)
  }

  func testSignedLibraryRequestsCarryNoBearerAndVerifyAgainstTheMemberKey() async throws {
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: .memory())
    let hello = try JSONEncoder().encode(LibraryHello(workspaceID: "library-b", hostName: "Box", capabilities: []))
    let http = RecordingHTTP { _ in (200, hello) }
    let box = UUID().uuidString.lowercased()
    let transport = try HTTPSLibraryTransport(host: URL(string: "https://box.tail1.ts.net/wovenmatter")!, hostDeviceID: box, identity: identity, performer: http)
    let bound = try await transport.workspaceIdentity()
    XCTAssertEqual(bound, "library-b")
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Woven-Workspace"))
    var headers: [String: String] = [:]
    for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
    let key = identity.publicKey
    let verifier = MemberRequestVerifier(audience: box, lookup: { id in id == identity.deviceID ? .init(deviceID: id, kind: .ios, name: "iPhone", publicKey: key) : nil })
    // A Linux host sees the path with Serve's `/wovenmatter` mount removed; both verify.
    let member = try await verifier.verify(method: "GET", target: "/v1/hello", headers: headers, body: Data(), allowing: [.ios])
    XCTAssertEqual(member.deviceID, identity.deviceID)
    XCTAssertEqual(MobileRequestSigning.target(of: request.url!), "/wovenmatter/v1/hello")
    XCTAssertEqual(headers["x-woven-member-audience"], box)
    // The same request at any other member is refused.
    let other = MemberRequestVerifier(audience: UUID().uuidString.lowercased(), lookup: { id in id == identity.deviceID ? .init(deviceID: id, kind: .ios, name: "iPhone", publicKey: key) : nil })
    do { _ = try await other.verify(method: "GET", target: "/v1/hello", headers: headers, body: Data(), allowing: [.ios]); XCTFail("Accepted elsewhere") }
    catch { XCTAssertEqual(error as? MemberRequestError, .audience) }
    // A host whose member device ID is unknown is skipped rather than signed for.
    XCTAssertThrowsError(try HTTPSLibraryTransport(host: URL(string: "https://box.tail1.ts.net/wovenmatter")!, hostDeviceID: "paired", identity: identity, performer: http))
  }

  /// An expanded row reads its activity once from the owner's details route,
  /// with free-form activity and run IDs in the query; a host chat's from
  /// the library host's. An owner without the route falls back to its transcript.
  func testExpandedActivitiesReadTheDetailsRouteOnce() async throws {
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: .memory())
    let full = LibraryActivity(id: "tool/1 #a", runID: "run 1", title: "Edit", status: "completed", projectionJSON: #"{"id":"tool/1 #a","kind":"tool","content":"full"}"#)
    let body = try JSONEncoder().encode(full)
    let http = RecordingHTTP { request in request.url!.path.hasSuffix("/activity") ? (200, body) : (404, Data()) }
    let mac = UUID().uuidString.lowercased()
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: mac, kind: .mac, name: "Studio",
                                       endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, executionDeviceID: mac)
    let direct = try HTTPSExecutionWorkspaceTransport(workspace: workspace, identity: identity, performer: http)
    let conversation = UUID().uuidString.lowercased()
    let read = try await direct.activityDetails(conversation, runID: "run 1", activityID: "tool/1 #a")
    XCTAssertEqual(read, full)
    let request = try XCTUnwrap(http.requests.last?.url)
    XCTAssertEqual(request.path, "/wovenmatter/v1/execution/conversations/\(conversation)/activity")
    let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "id" }?.value, "tool/1 #a")
    XCTAssertEqual(items.first { $0.name == "run" }?.value, "run 1")
    XCTAssertEqual(http.requests.count, 1)

    let library = try HTTPSLibraryTransport(host: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, hostDeviceID: mac, identity: identity, performer: http)
    let store = try MobileStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    let viaHost = try await MobileSyncEngine(store: store, transport: library).transcriptActivityDetail(conversation, runID: "run 1", activityID: "tool/1 #a")
    XCTAssertEqual(viaHost, full)
    XCTAssertEqual(http.requests.last?.url?.path, "/wovenmatter/v1/sessions/\(conversation)/activity")
    XCTAssertEqual(http.requests.count, 2, "One read per expansion; no transcript read when the route answers")
  }

  func testSignedFailuresDistinguishUnknownNotReadyAndUpdateRequired() {
    func body(_ code: String, _ message: String) -> Data { try! JSONEncoder().encode(LibraryAPIError(code: code, message: message)) }
    // A host that has not loaded its member list yet is not ready; it does not mean "pair again".
    guard case .http(401, _) = MobileRequestSigning.failure(status: 401, data: body("unauthorized", "This device does not accept member requests yet."), signed: true, fallback: "") else { return XCTFail() }
    guard case .http(401, _) = MobileRequestSigning.failure(status: 401, data: Data(#"{"error":"member_auth_unavailable"}"#.utf8), signed: true, fallback: "") else { return XCTFail() }
    guard case .memberUnknown = MobileRequestSigning.failure(status: 401, data: body("unauthorized", "This device is not a member, or it was removed."), signed: true, fallback: "") else { return XCTFail() }
    guard case .revoked = MobileRequestSigning.failure(status: 401, data: Data(), signed: false, fallback: "") else { return XCTFail() }
    guard case .updateRequired = MobileRequestSigning.failure(status: 409, data: body("update_required", "Mac Mini runs version 2."), signed: true, fallback: "") else { return XCTFail() }
  }

  func testHostCandidatesStayOnTheTailnetAndPreferTheLastHostThenMacsThenLinux() {
    var state = MobileMembershipState(deviceID: phoneID, pairedEndpoint: URL(string: "https://studio.tail1.ts.net:8443/wovenmatter")!,
                                      pairedHostDeviceID: "a0000000-0000-0000-0000-000000000001")
    state.members = [
      .init(deviceID: "a0000000-0000-0000-0000-000000000001", kind: "mac", name: "Studio", endpoints: [URL(string: "https://studio.tail1.ts.net:8443/wovenmatter")!]),
      .init(deviceID: "a0000000-0000-0000-0000-000000000002", kind: "mac", name: "Mini", endpoints: []),
      .init(deviceID: "a0000000-0000-0000-0000-000000000003", kind: "linux", name: "Box", endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter/")!]),
      .init(deviceID: "a0000000-0000-0000-0000-000000000004", kind: "linux", name: "Elsewhere", endpoints: [URL(string: "https://evil.other.ts.net/wovenmatter/")!]),
      .init(deviceID: "a0000000-0000-0000-0000-000000000005", kind: "mac", name: "Removed", endpoints: [URL(string: "https://gone.tail1.ts.net/wovenmatter")!], revoked: true),
      .init(deviceID: phoneID, kind: "ios", name: "iPhone", endpoints: []),
    ]
    let registry = [ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "lib", ownerDeviceID: "a0000000-0000-0000-0000-000000000002",
                                                kind: .mac, name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!)]
    XCTAssertEqual(state.candidates(registry: registry).map(\.name), ["Studio", "Mini", "Box"])
    state.preferredHostDeviceID = "a0000000-0000-0000-0000-000000000003"
    XCTAssertEqual(state.candidates(registry: registry).map(\.name), ["Box", "Studio", "Mini"])
    XCTAssertEqual(state.candidates(registry: registry).first?.endpoint.absoluteString, "https://box.tail1.ts.net/wovenmatter")
  }

  /// Only Macs record product analytics. Synced through a Linux host, the
  /// phone sends them to its preferred Mac; with no Mac it sends nothing.
  func testAnalyticsFollowTheCurrentMacAndSkipLinuxHosts() async throws {
    let studio = "a0000000-0000-0000-0000-000000000001", mini = "a0000000-0000-0000-0000-000000000002"
    let box = "a0000000-0000-0000-0000-000000000003"
    var state = MobileMembershipState(deviceID: phoneID, pairedEndpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, pairedHostDeviceID: studio)
    state.members = [
      .init(deviceID: studio, kind: "mac", name: "Studio", endpoints: [URL(string: "https://studio.tail1.ts.net/wovenmatter")!]),
      .init(deviceID: mini, kind: "mac", name: "Mini", endpoints: [URL(string: "https://mini.tail1.ts.net/wovenmatter")!]),
      .init(deviceID: box, kind: "linux", name: "Box", endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter")!]),
    ]
    let linux = MobileLibraryHost(deviceID: box, kind: "linux", name: "Box", endpoint: URL(string: "https://box.tail1.ts.net/wovenmatter")!)
    let other = MobileLibraryHost(deviceID: mini, kind: "mac", name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!)
    state.preferredHostDeviceID = box
    XCTAssertEqual(state.analyticsHost(current: linux)?.name, "Studio", "A Linux host never takes analytics; the paired Mac does")
    XCTAssertEqual(state.analyticsHost(current: other)?.name, "Mini", "The current Mac host takes them")
    XCTAssertEqual(state.analyticsHost(current: nil)?.name, "Studio")
    var linuxOnly = MobileMembershipState(deviceID: phoneID, pairedEndpoint: URL(string: "https://box.tail1.ts.net/wovenmatter")!, pairedHostDeviceID: box)
    linuxOnly.members = [.init(deviceID: box, kind: "linux", name: "Box", endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter")!])]
    XCTAssertNil(linuxOnly.analyticsHost(current: linux))

    // The engine-facing transport reaches the chosen Mac, not the Linux connection it synced with.
    let http = RecordingHTTP { _ in (200, Data("{}".utf8)) }
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: .memory())
    let hosts = try MobileLibraryHosts(state: state, identity: identity, file: nil, performer: http)
    let synced = try await hosts.transport(for: linux)
    let chosen = await hosts.analyticsTransport(current: linux, connection: synced)
    _ = try? await chosen?.analyticsPreference()
    XCTAssertEqual(http.requests.last?.url?.host, "studio.tail1.ts.net")
    let onMac = try await hosts.transport(for: other)
    let same = await hosts.analyticsTransport(current: other, connection: onMac)
    XCTAssertTrue(same === onMac, "Synced through a Mac, analytics reuse that connection")
  }

  func testConnectFailsOverToTheNextOnlineHostAndRemembersIt() async throws {
    var state = MobileMembershipState(deviceID: phoneID, pairedEndpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!)
    state.members = [.init(deviceID: "a0000000-0000-0000-0000-000000000003", kind: "linux", name: "Box", endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter/")!])]
    let hello = try JSONEncoder().encode(LibraryHello(workspaceID: "library-box", hostName: "Box", capabilities: []))
    let http = RecordingHTTP { request in
      guard request.url?.host == "box.tail1.ts.net" else { throw URLError(.cannotConnectToHost) }
      return (200, hello)
    }
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: .memory())
    let hosts = try MobileLibraryHosts(state: state, identity: identity, file: nil, performer: http)
    let (_, reply, host) = try await hosts.connect(registry: [])
    XCTAssertEqual(reply.workspaceID, "library-box")
    XCTAssertEqual(host.name, "Box")
    let next = await hosts.snapshot()
    XCTAssertEqual(next.preferredHostDeviceID, "a0000000-0000-0000-0000-000000000003")
    XCTAssertEqual(next.candidates().first?.name, "Box")
  }

  /// The move to another host of the same library: revisions are the host's,
  /// pending edits are rebased by content, and nothing local is lost.
  func testRebindingToAnotherHostRebasesPendingEditsByContent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let ids = (0..<5).map { _ in UUID().uuidString.lowercased() }
    let onA = ids.prefix(4).map { LibraryNote(id: $0, title: "Note \($0.prefix(4))", content: "base", revision: 7) }
    try await store.apply(LibrarySnapshot(workspaceID: "library-a", cursor: 40, notes: onA))
    // 0: clean. 1: edited, host B still has the base. 2: edited, B has another version.
    // 3: edited and already forwarded to B. 4: created here, never reached A or B.
    try await store.editNote(id: ids[1], title: onA[1].title, content: "phone edit", folderID: nil)
    try await store.editNote(id: ids[2], title: onA[2].title, content: "phone edit", folderID: nil)
    try await store.editNote(id: ids[3], title: onA[3].title, content: "sent before the move", folderID: nil)
    _ = try await store.createNote(folderID: nil, title: "New", content: "only here", id: ids[4])
    var onB = onA.map { var note = $0; note.revision = 3; return note }
    onB[2].content = "edited on the Linux host"
    onB[3].content = "sent before the move"
    try await store.rebindLibrary(to: LibrarySnapshot(workspaceID: "library-b", cursor: 5, notes: onB), bodies: [:])
    let state = await store.snapshot()
    XCTAssertEqual(state.workspaceID, "library-b")
    XCTAssertEqual(state.cursor, 5)
    XCTAssertEqual(state.notes[ids[0]]?.revision, 3)
    let update = try XCTUnwrap(state.outbox.first { $0.mutation.resourceID == ids[1] }?.mutation)
    XCTAssertEqual(update.kind, .updateNote); XCTAssertEqual(update.expectedRevision, 3); XCTAssertEqual(update.content, "phone edit")
    XCTAssertEqual(state.conflicts[ids[2]]?.local.content, "phone edit")
    XCTAssertEqual(state.conflicts[ids[2]]?.remote?.content, "edited on the Linux host")
    XCTAssertNil(state.outbox.first { $0.mutation.resourceID == ids[3] })
    XCTAssertEqual(state.notes[ids[3]]?.revision, 3)
    XCTAssertEqual(state.outbox.first { $0.mutation.resourceID == ids[4] }?.mutation.kind, .createNote)
    XCTAssertEqual(Set(state.notes.keys), Set(ids))
    try await store.bindWorkspace("library-b")
  }

  /// A clean note the new host deleted is deleted here too, not a conflict.
  func testRebindingAppliesADeletionMadeOnTheNewHost() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileStore(file: directory.appendingPathComponent("library.json"))
    let gone = UUID().uuidString.lowercased(), kept = UUID().uuidString.lowercased()
    try await store.apply(LibrarySnapshot(workspaceID: "library-a", cursor: 4, notes: [
      LibraryNote(id: gone, title: "Deleted elsewhere", content: "base", revision: 2),
      LibraryNote(id: kept, title: "Edited here", content: "base", revision: 2)]))
    try await store.editNote(id: kept, title: "Edited here", content: "phone edit", folderID: nil)
    try await store.rebindLibrary(to: LibrarySnapshot(workspaceID: "library-b", cursor: 9, notes: []), bodies: [:])
    let state = await store.snapshot()
    for id in [gone, kept] {
      let create = try XCTUnwrap(state.outbox.first { $0.mutation.resourceID == id }?.mutation)
      XCTAssertEqual(create.kind, .createNote)
      try await store.acknowledge(.init(operationID: create.operationID, status: .notFound, message: "Deleted", deleted: true))
    }
    let after = await store.snapshot()
    XCTAssertNil(after.notes[gone]); XCTAssertNil(after.conflicts[gone])
    XCTAssertTrue(after.outbox.isEmpty)
    XCTAssertEqual(after.conflicts[kept]?.local.content, "phone edit", "writing the host never saw is preserved")
  }

  func testAMissingMemberKeyIsReportedAsNew() throws {
    let storage = MobileMemberKeyStorage.memory()
    let device = UUID().uuidString.lowercased()
    let first = try MobileMemberKeyVault.loadOrCreateReportingNew(deviceID: device, storage: storage)
    XCTAssertTrue(first.created)
    let again = try MobileMemberKeyVault.loadOrCreateReportingNew(deviceID: device, storage: storage)
    XCTAssertFalse(again.created); XCTAssertEqual(again.identity.publicKey, first.identity.publicKey)
    // A restored backup: the same device ID, but this device's Keychain never held the key.
    let restored = try MobileMemberKeyVault.loadOrCreateReportingNew(deviceID: device, storage: .memory())
    XCTAssertTrue(restored.created); XCTAssertNotEqual(restored.identity.publicKey, first.identity.publicKey)
  }

  func testJournalRebindKeepsHistoryAndOffersOwnRecordsAgain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try WorkspaceJournal(file: directory.appendingPathComponent("execution"))
    let device = phoneID
    try await journal.upsertWorkspace(.init(id: device, libraryID: "library-a", ownerDeviceID: device, kind: .ios, name: "iPhone"))
    let conversation = UUID().uuidString.lowercased()
    _ = try await journal.append(workspaceID: device, conversation: .init(id: conversation, title: "Quick chat", runtimeKind: "default_agent"))
    let entries = await journal.pendingOwnerEntries(deviceID: device)
    try await journal.acknowledge(.init(libraryID: "library-a", acceptedEventIDs: entries.map(\.eventID), cursor: 1), submitted: entries)
    let drained = await journal.pendingOwnerEntries(deviceID: device)
    XCTAssertTrue(drained.isEmpty)
    try await journal.rebindLibrary(to: "library-b", deviceID: device)
    let state = await journal.snapshot()
    XCTAssertEqual(state.libraryID, "library-b")
    XCTAssertEqual(state.workspaces[device]?.libraryID, "library-b")
    XCTAssertTrue(state.pendingRegistrations.contains(device))
    let offered = await journal.pendingOwnerEntries(deviceID: device)
    XCTAssertEqual(offered.map(\.eventID), entries.map(\.eventID))
    XCTAssertNotNil(state.conversations[conversation])
  }
}
