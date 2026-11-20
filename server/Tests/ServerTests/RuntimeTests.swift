import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private let appVersion = "test"

/// The scripted ACP agent, built into the same folder as this test image.
private func fakeAgent() throws -> String {
  var info = dl_info()
  guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { throw RuntimeError.failed("Cannot find the test image.") }
  var url = URL(fileURLWithPath: String(cString: name))
  for _ in 0..<4 {
    url.deleteLastPathComponent()
    let candidate = url.appendingPathComponent("fake-acp-agent")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
  }
  throw RuntimeError.failed("fake-acp-agent was not built next to \(String(cString: name)).")
}

/// An ACP runtime that runs the fake agent, keeping its native sessions in `store`.
private func fakeRuntime(store: URL) throws -> ACPRuntime {
  let executable = try fakeAgent()
  return ACPRuntime(kind: .codex, profile: { _ in
    ACPProfile(kind: .codex, executable: executable, arguments: [], environment: ["FAKE_ACP_STORE": store.path])
  }, statusCheck: { RuntimeStatus(runtime: .codex, name: "Fake", installed: true) }, installer: {})
}

private struct Host {
  let server: WovenServer
  let folder: URL
  let socket: String

  static func start(folder: URL? = nil, runtime: any Runtime, tailnet: StandInTailnet = StandInTailnet(),
                    listen: Bool = false) async throws -> Host {
    let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("woven-runtime-\(UUID().uuidString)")
    let socket = "/tmp/wvr-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: listen ? ("127.0.0.1", 0) : nil,
                                      appVersion: appVersion, machineName: "test", tailnet: tailnet, runtimes: [runtime],
                                      discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return Host(server: try await WovenServer.start(options), folder: folder, socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }
}

/// Sends a turn and collects its events until the session is idle again,
/// answering any approval with `approve`.
@discardableResult
private func turn(_ client: Client, _ sessionID: String, _ text: String, approve: String? = nil) async throws -> [SessionEvent] {
  let subscription = try await client.subscribe(SubscribeSession(sessionID: sessionID))
  _ = try await client.call(SendTurn(sessionID: sessionID, text: text))
  var events: [SessionEvent] = []
  for try await event in subscription.events {
    events.append(event)
    if case .awaiting(let prompt) = event, let approve {
      _ = try await client.call(AnswerPrompt(sessionID: sessionID, promptID: prompt.id, answer: approve))
    }
    if event == .runState(.idle) { break }
  }
  try await client.unsubscribe(subscription.id)
  return events
}

private func assistantTexts(_ items: [SessionItem]) -> [String] {
  items.compactMap { if case .assistantMessage(let text) = $0.content { text } else { nil } }
}

@Test(.timeLimit(.minutes(1)))
func acpProcessStaysAliveAcrossTurnsAndStreamsToolsApprovalsAndUsage() async throws {
  let store = FileManager.default.temporaryDirectory.appendingPathComponent("fake-acp-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
  let host = try await Host.start(runtime: try fakeRuntime(store: store))
  defer { Task { await host.server.stop() } }
  let client = try await host.connect()
  let session = try await client.call(CreateSession(runtime: .codex, title: "Chat"))
  #expect(!session.directory.isEmpty && FileManager.default.fileExists(atPath: session.directory))

  let configured = try await client.call(ConfigureSession(sessionID: session.id, model: "fake-large"))
  #expect(configured.model == "fake-large")
  #expect(configured.models.map(\.id) == ["fake-small", "fake-large"])

  let first = try await turn(client, session.id, "one")
  #expect(first.contains { if case .text = $0 { true } else { false } })
  try await turn(client, session.id, "needs permission", approve: "allow")

  let items = try await client.call(SessionItems(sessionID: session.id))
  let texts = assistantTexts(items)
  #expect(texts.count == 2)
  let pids = texts.compactMap { $0.split(separator: " ").dropFirst().first }
  #expect(pids.count == 2 && pids[0] == pids[1])
  #expect(texts[1].hasSuffix("turn 2: needs permission (allow)"))
  let tools = items.compactMap { if case .toolCall(let call) = $0.content { call } else { nil } }
  #expect(tools.map(\.kind) == [.execute, .execute])
  #expect(tools.allSatisfy { $0.output == "a.txt" && !$0.failed })
  #expect(Set(items.map(\.id)).count == items.count)

  let usage = try await host.server.library.rows("usage_records", where: "session_id", is: .text(session.id))
  #expect(usage.count == 2)
  #expect(usage.allSatisfy { $0.values["input_tokens"] == .integer(3) && $0.values["model"] == .text("fake-large") })
}

@Test(.timeLimit(.minutes(1)))
func acpSessionResumesAfterRestartAndSaysWhenTheRuntimeLostIt() async throws {
  let store = FileManager.default.temporaryDirectory.appendingPathComponent("fake-acp-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
  let runtime = try fakeRuntime(store: store)
  let first = try await Host.start(runtime: runtime)
  let client = try await first.connect()
  let kept = try await client.call(CreateSession(runtime: .codex, title: "Kept"))
  let lost = try await client.call(CreateSession(runtime: .codex, title: "Lost"))
  try await turn(client, kept.id, "one")
  try await turn(client, lost.id, "one")
  await first.server.stop()

  // The runtime loses one native session while the server is down.
  let second = try await Host.start(folder: first.folder, runtime: runtime)
  defer { Task { await second.server.stop() } }
  let handle = try await second.server.library.nativeSession(for: lost.id)!.handle
  try FileManager.default.removeItem(at: store.appendingPathComponent(handle))
  let again = try await second.connect()

  try await turn(again, kept.id, "two")
  let keptItems = try await again.call(SessionItems(sessionID: kept.id))
  // Resumed with its history, which the replay did not add to the library again.
  #expect(assistantTexts(keptItems).map { $0.split(separator: " ").dropFirst(2).joined(separator: " ") }
          == ["turn 1: one", "turn 2: two"])
  #expect(keptItems.map(\.sequence) == Array(1...6))

  let refused = await #expect(throws: ProtocolError.self) {
    _ = try await again.call(SendTurn(sessionID: lost.id, text: "two"))
  }
  #expect(refused?.code == .nativeSessionGone)
  let lostItems = try await again.call(SessionItems(sessionID: lost.id))
  guard case .notice(let notice) = lostItems.last?.content else {
    Issue.record("The last item is not a notice")
    return
  }
  #expect(notice.kind == .nativeSessionGone)
  // No fresh native session was started in its place.
  #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(handle).path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func serverStoppedMidTurnLeavesOneNotice() async throws {
  let store = StandInRuntime.NativeStore()
  let first = try await Host.start(runtime: StandInRuntime(store: store, gate: StandInRuntime.Gate()))
  let client = try await first.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  let subscription = try await client.subscribe(SubscribeSession(sessionID: session.id))
  _ = try await client.call(SendTurn(sessionID: session.id, text: "held"))
  for try await event in subscription.events { if case .text = event { break } }
  await first.server.stop()

  let second = try await Host.start(folder: first.folder, runtime: StandInRuntime(store: store))
  defer { Task { await second.server.stop() } }
  let items = try await (try await second.connect()).call(SessionItems(sessionID: session.id))
  let notices = items.compactMap { if case .notice(let notice) = $0.content { notice.kind } else { nil } }
  #expect(notices == [.interrupted])
}

@Test func onlyTheAddressedMachineCanOpenASealedSecret() throws {
  let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
  let sealed = try Sealing.seal(Data("sk-test".utf8), name: "openai", for: a.publicKey)
  #expect(try Sealing.open(sealed, name: "openai", with: a) == Data("sk-test".utf8))
  #expect(throws: (any Error).self) { try Sealing.open(sealed, name: "openai", with: b) }
  // A sealed copy cannot be passed off as another provider's key.
  #expect(throws: (any Error).self) { try Sealing.open(sealed, name: "anthropic", with: a) }
}

@Test(.timeLimit(.minutes(1)))
func apiKeyIsSealedForEachMachineAndContentIsFetchedByDigest() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await Host.start(runtime: StandInRuntime(), tailnet: tailnetA, listen: true)
  let b = try await Host.start(runtime: StandInRuntime(), tailnet: tailnetB, listen: true)
  defer { Task { await a.server.stop(); await b.server.stop() } }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()
  let onA = try await a.connect(), onB = try await b.connect()

  // A attachment stored on A is fetched by B's UI through B, by digest.
  let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
  let stored = try await onA.call(PutContent(data: bytes))
  var fetched = Data()
  for _ in 0..<200 {
    if let chunk = try? await onB.call(FetchContent(digest: stored.digest)) {
      fetched = chunk.data
      break
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(fetched == bytes)
  #expect(try await b.server.library.hasContent(stored.digest))

  // Once B's public key has reached A, a key set on A reaches B sealed for B.
  for _ in 0..<200 where try await a.server.library.machines().count < 2 { try await Task.sleep(for: .milliseconds(25)) }
  _ = try await onA.call(SetAPIKey(provider: "openai", key: "sk-test"))
  var opened: [String: String] = [:]
  for _ in 0..<200 {
    opened = try await b.server.secretsForTests.apiKeys()
    if !opened.isEmpty { break }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(opened == ["openai": "sk-test"])
  let rows = try await b.server.library.rows("sealed_secrets", where: "name", is: .text("openai"))
  #expect(Set(rows.compactMap { if case .text(let id)? = $0.values["machine_id"] { id } else { nil } })
          == [a.server.machineID, b.server.machineID])

  _ = try await onB.call(SetAPIKey(provider: "openai", key: nil))
  for _ in 0..<200 where try await !a.server.secretsForTests.apiKeys().isEmpty { try await Task.sleep(for: .milliseconds(25)) }
  #expect(try await a.server.secretsForTests.apiKeys().isEmpty)
}
