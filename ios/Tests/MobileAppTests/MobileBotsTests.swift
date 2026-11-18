import CryptoKit
import XCTest
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

/// The Bots page: which machine runs bots, the signed status request, and a live
/// conversation over Pi Bot's protocol against a scripted runtime on a loopback socket.
/// Nothing leaves this device.
@MainActor
final class MobileBotsTests: XCTestCase {
  private let phone = "f0000000-0000-0000-0000-000000000001"
  private let studio = "a0000000-0000-0000-0000-000000000001"
  private let mini = "a0000000-0000-0000-0000-000000000002"
  private let box = "a0000000-0000-0000-0000-000000000003"

  private func workspace(_ name: String, kind: ExecutionWorkspace.Kind, device: String?, endpoint: String?,
                         deleted: Bool = false) -> ExecutionWorkspace {
    ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "lib", ownerDeviceID: device ?? studio, kind: kind, name: name,
                       endpoint: endpoint.flatMap(URL.init(string:)), executionDeviceID: device, deleted: deleted)
  }

  private var membership: MobileMembershipState {
    var state = MobileMembershipState(deviceID: phone, pairedEndpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!,
                                      pairedHostDeviceID: studio)
    state.members = [
      .init(deviceID: studio, kind: "mac", name: "Studio", endpoints: [URL(string: "https://studio.tail1.ts.net/wovenmatter")!]),
      .init(deviceID: mini, kind: "mac", name: "Mini", endpoints: []),
      .init(deviceID: box, kind: "linux", name: "Box", endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter/")!]),
      .init(deviceID: phone, kind: "ios", name: "iPhone", endpoints: []),
    ]
    return state
  }

  private func status(_ device: String, name: String, kind: String = "mac", enabled: Bool, state: String, message: String? = nil) -> BotsRemoteStatus {
    BotsRemoteStatus(machine: .init(deviceID: device, name: name, kind: kind), enabled: enabled, state: state, message: message,
                     versions: .init(app: "0.0.1", runtime: "0.1.0", protocol: 1))
  }

  func testEveryMacAndLinuxWorkspaceIsCheckedOncePerServingMember() {
    let workspaces = [
      workspace("Studio", kind: .mac, device: studio, endpoint: "https://studio.tail1.ts.net/wovenmatter"),
      workspace("Studio (old)", kind: .mac, device: studio, endpoint: "https://studio.tail1.ts.net/wovenmatter"),
      workspace("Mini", kind: .mac, device: mini, endpoint: nil),
      workspace("Box", kind: .linux, device: nil, endpoint: "https://box.tail1.ts.net/wovenmatter-execution/abc/"),
      workspace("Gone", kind: .mac, device: mini, endpoint: "https://mini.tail1.ts.net/wovenmatter", deleted: true),
      workspace("This iPhone", kind: .ios, device: phone, endpoint: nil),
    ]
    let targets = MobileBotsModel.targets(workspaces: workspaces, membership: membership)
    XCTAssertEqual(targets.map(\.workspace.name), ["Studio", "Box"])
    XCTAssertEqual(targets.map(\.audience), [studio, box])
    XCTAssertEqual(MobileBotsModel.targets(workspaces: workspaces, membership: nil), [])
  }

  /// The status request carries this phone's member signature for that machine only,
  /// and a reply that names another device is refused.
  func testStatusIsSignedForTheMachineAndMustAnswerAsIt() async throws {
    let key = Curve25519.Signing.PrivateKey(), signer = MemberRequestSigner(deviceID: phone, key: key)
    let target = MobileBotTarget(workspace: workspace("Studio", kind: .mac, device: studio, endpoint: "https://studio.tail1.ts.net/wovenmatter"),
                                 audience: studio)
    let http = BotsStatusHTTP(reply: try JSONEncoder().encode(status(studio, name: "Studio", enabled: true, state: "ready")))
    let answer = try await MobileBotsModel.status(of: target, signer: signer, performer: http)
    XCTAssertEqual(answer.machine.name, "Studio")
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.url?.path, "/wovenmatter/v1/bots/status")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    let member = MemberKey(deviceID: phone, kind: .ios, name: "iPhone", publicKey: key.publicKey.rawRepresentation), phone = phone
    let there = MemberRequestVerifier(audience: studio, lookup: { $0 == phone ? member : nil })
    let verified = try await there.verify(method: "GET", target: "/wovenmatter/v1/bots/status", headers: headers, body: Data(), allowing: [.ios])
    XCTAssertEqual(verified, member)
    let elsewhere = MemberRequestVerifier(audience: mini, lookup: { $0 == phone ? member : nil })
    do {
      _ = try await elsewhere.verify(method: "GET", target: "/wovenmatter/v1/bots/status", headers: headers, body: Data(), allowing: [.ios])
      XCTFail("A signature for Studio must not verify on another machine.")
    } catch {}

    let impostor = BotsStatusHTTP(reply: try JSONEncoder().encode(status(mini, name: "Mini", enabled: true, state: "ready")))
    do {
      _ = try await MobileBotsModel.status(of: target, signer: signer, performer: impostor)
      XCTFail("A reply from another device must be refused.")
    } catch { XCTAssertEqual((error as? MobileBotsError)?.message, "It answered as another device.") }

    let old = BotsStatusHTTP(reply: Data(), status: 404)
    do {
      _ = try await MobileBotsModel.status(of: target, signer: signer, performer: old)
      XCTFail("A server without bots routes must say so.")
    } catch { XCTAssertEqual((error as? MobileBotsError)?.message, "Its Woven server doesn't run bots yet. Update it to use bots there.") }
  }

  func testThePlacementIsTheMachineWithBotsTurnedOn() {
    let mac = MobileBotTarget(workspace: workspace("Studio", kind: .mac, device: studio, endpoint: "https://studio.tail1.ts.net/wovenmatter"), audience: studio)
    let linux = MobileBotTarget(workspace: workspace("Box", kind: .linux, device: box, endpoint: "https://box.tail1.ts.net/wovenmatter-execution/abc/"), audience: box)
    let offline = MobileBotTarget(workspace: workspace("Mini", kind: .mac, device: mini, endpoint: "https://mini.tail1.ts.net/wovenmatter"), audience: mini)

    // Bots run on the Linux host; the Mac has them off.
    guard case .ready(let machine) = MobileBotsModel.placement([
      (mac, .success(status(studio, name: "Studio", enabled: false, state: "off"))),
      (linux, .success(status(box, name: "Box", kind: "linux", enabled: true, state: "ready"))),
    ]) else { return XCTFail("Expected the Linux host") }
    XCTAssertEqual(machine.name, "Box")
    XCTAssertEqual(machine.audience, box)
    XCTAssertEqual(machine.socketURL.absoluteString, "https://box.tail1.ts.net/wovenmatter-execution/abc/v1/bots/ws")

    // A ready machine wins over one that is still starting.
    guard case .ready(let ready) = MobileBotsModel.placement([
      (mac, .success(status(studio, name: "Studio", enabled: true, state: "starting"))),
      (linux, .success(status(box, name: "Box", kind: "linux", enabled: true, state: "ready"))),
    ]) else { return XCTFail("Expected the ready machine") }
    XCTAssertEqual(ready.deviceID, box)

    XCTAssertEqual(MobileBotsModel.placement([(mac, .success(status(studio, name: "Studio", enabled: true, state: "starting")))]),
                   .unavailable(name: "Studio", message: "Bots are starting there."))

    // Nobody runs bots: every machine says why.
    XCTAssertEqual(MobileBotsModel.placement([
      (mac, .success(status(studio, name: "Studio", enabled: false, state: "off"))),
      (offline, .failure(MobileBotsError("The request timed out."))),
    ]), .off([.init(id: studio, name: "Studio", detail: "Bots are off"), .init(id: mini, name: "Mini", detail: "The request timed out.")]))
  }

  func testAPhoneThatIsNotPairedDoesNotLook() async {
    let bots = MobileBotsModel()
    await bots.refresh(targets: [], signer: nil, performer: BotsStatusHTTP(reply: Data()))
    XCTAssertEqual(bots.placement, .unpaired)
    XCTAssertNil(bots.session)
  }

  /// The real client and conversation logic against a scripted runtime: the bot list,
  /// history, a sent message with its streamed reply, and a thread showing only its own replies.
  func testBotsLoadAndAReplyStreamsIntoTheConversation() async throws {
    let runtime = ScriptedBotsRuntime()
    runtime.wordDelay = 0
    let port = try await runtime.start()
    defer { runtime.stop() }
    let bots = MobileBotsModel()
    bots.apply(.ready(.init(deviceID: "studio", name: "Studio", kind: "mac",
                            socketURL: URL(string: "ws://127.0.0.1:\(port)/ws")!, audience: nil, bearer: "fixture")))
    let session = try XCTUnwrap(bots.session)
    try await eventually { session.hasLoadedBots }
    XCTAssertEqual(session.layout.pinned.map(\.bot.name), ["Admin Bot", "Atlas"])
    XCTAssertEqual(session.layout.groups.first?.rows.map(\.bot.name), ["Research", "Scout"])
    XCTAssertEqual(session.layout.groups.first?.rows.map(\.isTeamMember), [false, true])
    XCTAssertEqual(session.layout.ungrouped.map(\.bot.name), ["Errands"])

    let main = session.conversation(botID: "atlas", conversationID: nil)
    main.attach()
    try await eventually { main.isReady }
    XCTAssertEqual(main.visibleEntries.count, 3)
    XCTAssertFalse(main.isThread)
    let sent = await main.send(text: "Check the launch checklist", context: nil)
    XCTAssertTrue(sent)
    try await eventually { main.visibleEntries.count == 5 && !main.state.running }
    XCTAssertEqual(main.visibleEntries.suffix(2).map(\.role), ["user", "assistant"])
    XCTAssertEqual(main.visibleEntries.last?.text, "On it. I'll check the launch checklist and send you a summary in this conversation.")
    XCTAssertTrue(main.state.pending.isEmpty)
    XCTAssertNil(main.state.streaming)
    try await eventually { session.threads(for: "atlas").count == 1 }
    XCTAssertEqual(session.threads(for: "atlas").first?.label, "Launch post sources")

    let thread = session.conversation(botID: "atlas", conversationID: 12)
    thread.attach()
    try await eventually { thread.isReady }
    XCTAssertTrue(thread.isThread)
    XCTAssertEqual(thread.visibleEntries.map(\.id), [4, 5])
    XCTAssertEqual(thread.origin?.id, 3)
    thread.detach(); main.detach()

    // Leaving the app closes the socket; coming back reconnects and reopens.
    bots.setForeground(false)
    try await eventually { !session.isConnected }
    main.attach()
    bots.setForeground(true)
    try await eventually { main.isReady }
    XCTAssertEqual(main.visibleEntries.count, 5)
    main.detach()
    // Leaving a conversation ends its subscription on the runtime.
    try await eventually { runtime.requests.contains("conversation.close") }
  }

  private struct TimedOut: Error {}
  private func eventually(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
                          _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting", file: file, line: line); throw TimedOut() }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

private final class BotsStatusHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  let reply: Data
  let status: Int
  init(reply: Data, status: Int = 200) { self.reply = reply; self.status = status }
  var requests: [URLRequest] { lock.withLock { recorded } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    return (reply, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
