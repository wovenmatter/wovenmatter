import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private let appVersion = "test"

/// A server with its own temporary data folder and a short socket path.
private struct TestServer {
  let server: WovenServer
  let folder: URL
  let socket: String

  static func start(folder: URL? = nil, runtime: any Runtime, tailnet: StandInTailnet = StandInTailnet(),
                    listen: Bool = false) async throws -> TestServer {
    let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: listen ? ("127.0.0.1", 0) : nil, appVersion: appVersion,
      machineName: "test", tailnet: tailnet, runtimes: [runtime], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    let server = try await WovenServer.start(options)
    return TestServer(server: server, folder: folder, socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }
}

/// Sends a turn and waits until the session is idle again.
private func turn(_ client: Client, _ sessionID: String, _ text: String) async throws {
  let subscription = try await client.subscribe(SubscribeSession(sessionID: sessionID))
  _ = try await client.call(SendTurn(sessionID: sessionID, text: text))
  for try await event in subscription.events where event == .runState(.idle) { break }
  try await client.unsubscribe(subscription.id)
}

/// What a subscriber shows: its snapshot with the events after it applied.
private struct View {
  var items: [SessionItem]
  var inProgress: [LiveItem]
  var run: RunState

  init(_ snapshot: SessionSnapshot) {
    items = snapshot.items
    inProgress = snapshot.inProgress
    run = snapshot.run
  }

  mutating func apply(_ event: SessionEvent) {
    switch event {
    case .itemStarted(let item): inProgress.append(item)
    case .text(let id, let delta):
      if let index = inProgress.firstIndex(where: { $0.id == id }), case .assistantMessage(let text) = inProgress[index].content {
        inProgress[index].content = .assistantMessage(text: text + delta)
      }
    case .toolActivity(let id, let call):
      if let index = inProgress.firstIndex(where: { $0.id == id }) { inProgress[index].content = .toolCall(call) }
    case .toolOutput(let id, let delta):
      if let index = inProgress.firstIndex(where: { $0.id == id }), case .toolCall(var call) = inProgress[index].content {
        call.output = (call.output ?? "") + delta
        inProgress[index].content = .toolCall(call)
      }
    case .itemFinished(let item):
      inProgress.removeAll { $0.id == item.id }
      items.append(item)
    case .itemDropped(let id): inProgress.removeAll { $0.id == id }
    case .runState(let state): run = state
    case .awaiting, .answered, .configuration: break
    }
  }
}

private func assistantTexts(_ items: [SessionItem]) -> [String] {
  items.compactMap { if case .assistantMessage(let text) = $0.content { text } else { nil } }
}

@Test(.timeLimit(.minutes(1)))
func streamedSessionIsSavedOnceAndALateSubscriberSeesAConsistentView() async throws {
  let gate = StandInRuntime.Gate()
  let host = try await TestServer.start(runtime: StandInRuntime(gate: gate))
  defer { host.server.stopLater() }
  let early = try await host.connect()
  let session = try await early.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  let first = try await early.subscribe(SubscribeSession(sessionID: session.id))
  var earlyView = View(first.reply)
  var earlyEvents = first.events.makeAsyncIterator()

  _ = try await early.call(SendTurn(sessionID: session.id, text: "hello"))
  // Wait for the first piece of text; the turn is now held mid-message.
  while let event = try await earlyEvents.next() {
    earlyView.apply(event)
    if case .text = event { break }
  }

  let late = try await host.connect()
  let second = try await late.subscribe(SubscribeSession(sessionID: session.id))
  var lateView = View(second.reply)
  #expect(lateView.items.map(\.content) == [.userMessage(text: "hello")])
  #expect(lateView.inProgress.map(\.content) == [.assistantMessage(text: "Turn 1: ")])
  #expect(lateView.run == .running)

  await gate.open()
  for try await event in second.events {
    lateView.apply(event)
    if event == .runState(.idle) { break }
  }
  while let event = try await earlyEvents.next() {
    earlyView.apply(event)
    if event == .runState(.idle) { break }
  }

  let saved = try await late.call(SessionItems(sessionID: session.id))
  #expect(saved.count == 3)
  #expect(Set(saved.map(\.id)).count == 3)
  #expect(assistantTexts(saved) == ["Turn 1: hello"])
  #expect(lateView.items == saved)
  #expect(earlyView.items == saved)
  #expect(lateView.inProgress.isEmpty && earlyView.inProgress.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMessageSentDuringATurnSteersItAndIsSavedOnceInOrder() async throws {
  let gate = StandInRuntime.Gate()
  let host = try await TestServer.start(runtime: StandInRuntime(gate: gate))
  defer { host.server.stopLater() }
  let client = try await host.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  let subscription = try await client.subscribe(SubscribeSession(sessionID: session.id))
  var events = subscription.events.makeAsyncIterator()
  _ = try await client.call(SendTurn(sessionID: session.id, text: "one"))
  while let event = try await events.next() {
    if case .text = event { break }
  }

  _ = try await client.call(SendTurn(sessionID: session.id, text: "two"))
  await gate.open()
  var runStates: [RunState] = []
  while let event = try await events.next() {
    if case .runState(let state) = event { runStates.append(state) }
    if event == .runState(.idle) { break }
  }

  let items = try await client.call(SessionItems(sessionID: session.id))
  #expect(runStates == [.idle])
  #expect(items.count == 5 && Set(items.map(\.id)).count == 5)
  #expect(Array(items.prefix(4).map(\.content)) == [
    .userMessage(text: "one"), .assistantMessage(text: "Turn 1: "), .userMessage(text: "two"), .assistantMessage(text: "one + two"),
  ])
}

@Test(.timeLimit(.minutes(1)))
func secondServerReceivesTheSessionBySyncAndServesItReadOnly() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await TestServer.start(runtime: StandInRuntime(), tailnet: tailnetA, listen: true)
  let b = try await TestServer.start(runtime: StandInRuntime(), tailnet: tailnetB, listen: true)
  defer { a.server.stopLater(); b.server.stopLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()

  let onA = try await a.connect()
  let session = try await onA.call(CreateSession(runtime: StandInRuntime.kind, title: "Owned by A"))
  try await turn(onA, session.id, "hello")
  let onAItems = try await onA.call(SessionItems(sessionID: session.id))

  let onB = try await b.connect()
  var copied: [SessionItem] = []
  for _ in 0..<200 where copied.count < onAItems.count {
    copied = try await onB.call(SessionItems(sessionID: session.id))
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(copied == onAItems)
  #expect(try await onB.call(ListSessions()).map(\.machineID) == [a.server.machineID])
  #expect(try await onB.call(ListMachines()).first { $0.machine.id == a.server.machineID }?.online == true)

  let refused = await #expect(throws: ProtocolError.self) {
    _ = try await onB.call(SendTurn(sessionID: session.id, text: "from b"))
  }
  #expect(refused?.code == .notOwner)
  #expect(refused?.machineID == a.server.machineID)
  #expect(try await onB.call(SessionItems(sessionID: session.id)) == onAItems)
}

@Test(.timeLimit(.minutes(1)))
func restartResumesTheSameNativeSession() async throws {
  let store = StandInRuntime.NativeStore()
  let first = try await TestServer.start(runtime: StandInRuntime(store: store))
  let client = try await first.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  try await turn(client, session.id, "one")
  await first.server.stop()

  let second = try await TestServer.start(folder: first.folder, runtime: StandInRuntime(store: store))
  defer { second.server.stopLater() }
  let again = try await second.connect()
  try await turn(again, session.id, "two")

  let items = try await again.call(SessionItems(sessionID: session.id))
  #expect(items.map(\.sequence) == Array(1...6))
  #expect(assistantTexts(items) == ["Turn 1: one", "Turn 2: two"])
  #expect(store.started == 1)
  #expect(store.resumed == 1)
}

@Test(.timeLimit(.minutes(1)))
func lostNativeSessionGivesANoticeAndNeverAFreshSession() async throws {
  let store = StandInRuntime.NativeStore()
  let first = try await TestServer.start(runtime: StandInRuntime(store: store))
  let client = try await first.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  try await turn(client, session.id, "one")
  await first.server.stop()
  store.forgetAll()

  let second = try await TestServer.start(folder: first.folder, runtime: StandInRuntime(store: store))
  defer { second.server.stopLater() }
  let again = try await second.connect()
  for _ in 0..<2 {
    let error = await #expect(throws: ProtocolError.self) {
      _ = try await again.call(SendTurn(sessionID: session.id, text: "two"))
    }
    #expect(error?.code == .nativeSessionGone)
  }

  let items = try await again.call(SessionItems(sessionID: session.id))
  #expect(items.count == 4)
  guard case .notice(let notice) = items.last?.content else {
    Issue.record("The last item is not a notice")
    return
  }
  #expect(notice.kind == .nativeSessionGone)
  #expect(store.started == 1)
  let snapshot = try await again.subscribe(SubscribeSession(sessionID: session.id)).reply
  #expect(snapshot.run == .nativeSessionGone)
}
