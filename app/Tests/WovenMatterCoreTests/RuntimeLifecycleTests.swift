import Darwin
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

struct RuntimeLifecycleTests {
  @Test func cancelledLocalStartupTerminatesUnreadyProcess() async throws {
    let state = FakeGatewayProcess()
    let gate = RuntimeGate()
    let lifecycle = OpenClawLocalGatewayLifecycle(launchProcess: { _, _ in state.launch() },
      isReady: { _ in false }, pause: { await gate.pause() })
    let start = Task { try await lifecycle.ensure(agentID: UUID(), identity: "cancel", launch: launch,
                                                   workingDirectory: URL(filePath: "/private/tmp")) }
    await gate.waitForArrivals(1)
    start.cancel()
    await gate.release(0)
    do { _ = try await start.value; Issue.record("cancelled startup succeeded") }
    catch is CancellationError { }
    #expect(!state.running)
    await lifecycle.shutdown()
  }

  @Test func shutdownTracksProcessWhileStartupIsSuspended() async throws {
    let state = FakeGatewayProcess()
    let gate = RuntimeGate()
    let lifecycle = OpenClawLocalGatewayLifecycle(launchProcess: { _, _ in state.launch() },
      isReady: { _ in false }, pause: { await gate.pause() })
    let start = Task { try await lifecycle.ensure(agentID: UUID(), identity: "shutdown", launch: launch,
                                                   workingDirectory: URL(filePath: "/private/tmp")) }
    await gate.waitForArrivals(1)
    await lifecycle.shutdown()
    #expect(!state.running)
    await gate.release(0)
    do { _ = try await start.value; Issue.record("shutdown startup succeeded") } catch { }
    do {
      _ = try await lifecycle.ensure(agentID: UUID(), identity: "new", launch: launch,
                                     workingDirectory: URL(filePath: "/private/tmp"))
      Issue.record("shutdown lifecycle restarted")
    } catch is CancellationError { }
    #expect(state.launches == 1)
  }

  @Test func sharedLocalStartupRetainsUntilBothAgentsRelease() async throws {
    let state = FakeGatewayProcess()
    let gate = RuntimeGate()
    let lifecycle = OpenClawLocalGatewayLifecycle(launchProcess: { _, _ in state.launch() },
      isReady: { _ in state.ready }, pause: { await gate.pause() })
    let firstID = UUID(), secondID = UUID()
    let first = Task { try await lifecycle.ensure(agentID: firstID, identity: "shared", launch: launch,
                                                   workingDirectory: URL(filePath: "/private/tmp")) }
    await gate.waitForArrivals(1)
    let second = Task { try await lifecycle.ensure(agentID: secondID, identity: "shared", launch: launch,
                                                    workingDirectory: URL(filePath: "/private/tmp")) }
    state.setReady()
    await gate.release(0)
    #expect(try await first.value == second.value)
    #expect(state.launches == 1)
    await lifecycle.release(agentID: firstID)
    #expect(state.running)
    await lifecycle.release(agentID: secondID)
    #expect(!state.running)
  }

  @Test func staleGatewayConnectionCannotClearOrReplaceNewConnection() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let agentID = UUID()
    let endpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)
    try database.saveOpenClawGatewayLink(OpenClawGatewayLink(agentID: agentID, location: .localAgentWorkspace, endpoint: endpoint))
    let gate = RuntimeGate()
    let coordinator = OpenClawGatewayCoordinator(database: database, connectClient: { _ in
      await gate.pause()
      return OpenClawGatewayCapabilities(methods: [], events: [])
    })
    let old = Task { try await coordinator.client(agentID: agentID) }
    await gate.waitForArrivals(1)
    await coordinator.configureTransport(agentID: agentID, endpoint: endpoint, requestHeaders: ["fixture": "new"])
    let new = Task { try await coordinator.client(agentID: agentID) }
    await gate.waitForArrivals(2)
    await gate.release(0)
    do { _ = try await old.value; Issue.record("stale connection returned") } catch is CancellationError { }
    await gate.release(1)
    let expected = try await new.value
    #expect(try await coordinator.client(agentID: agentID) === expected)
    #expect(try database.openClawGatewayLinks().first?.connectionStatus == .ready)
    await coordinator.disconnect(agentID: agentID)
  }

  @Test func cancelledACPStartupShutsDriverDownAndAllowsRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try database.createLocalACPSession(runtimeKind: .codex, title: "fixture", ownerDeviceID: UUID())
    let gate = RuntimeGate()
    let state = FakeGatewayProcess()
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      let process = state.launch()
      return LocalACPSessionDriver(initializeSession: { _, _, _, _ in
        await gate.pause()
        try Task.checkCancellation()
        return LocalACPInitializedSession(sessionID: "fixture", loadedExistingSession: false)
      }, prompt: { _, _, _, _ in .endTurn }, configuration: { .empty },
      setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: { process.terminate() })
    })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
    let start = Task { try await coordinator.configuration(conversationID: conversation, launch: launch, workspace: workspace) }
    await gate.waitForArrivals(1)
    start.cancel()
    do { _ = try await start.value; Issue.record("cancelled ACP start returned") } catch is CancellationError { }
    #expect(!state.running)
    let retry = Task { try await coordinator.configuration(conversationID: conversation, launch: launch, workspace: workspace) }
    await gate.waitForArrivals(2)
    await gate.release(1)
    _ = try await retry.value
    #expect(state.launches == 2)
    await coordinator.shutdown()
    #expect(!state.running)
  }

  @Test(arguments: [true, false])
  func actualOwnedProcessIsReapedAfterCancellationOrShutdown(cancel: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appending(path: "pid")
    let gate = RuntimeGate()
    // The shell immediately execs sleep: one harmless process, no child tree or provider.
    // Ignoring TERM deliberately exercises the bounded SIGKILL escalation.
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .openclaw,
      executableURL: URL(filePath: "/bin/sh"), arguments: ["-c",
        "trap '' TERM; echo $$ > '\(pidFile.path)'; exec /bin/sleep 60"])
    let lifecycle = OpenClawLocalGatewayLifecycle(isReady: { _ in false }, pause: { await gate.pause() })
    let start = Task { try await lifecycle.ensure(agentID: UUID(), identity: UUID().uuidString,
      launch: launch, workingDirectory: directory) }
    await gate.waitForArrivals(1)
    var pid: Int32?
    for _ in 0..<100 {
      if let text = try? String(contentsOf: pidFile, encoding: .utf8),
         let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = value; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard let pid else {
      await lifecycle.shutdown()
      Issue.record("fixture process did not write its PID")
      return
    }
    if cancel { start.cancel() } else { await lifecycle.shutdown() }
    do { _ = try await start.value; Issue.record("interrupted process startup succeeded") } catch { }
    #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    await lifecycle.shutdown()
  }

  @Test(arguments: ["model", "thinking"], [false, true])
  func lateStartupConfigurationCannotSurviveInterruption(stage: String, shutdown: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try database.createLocalACPSession(runtimeKind: .codex, title: "fixture", ownerDeviceID: UUID())
    try database.updateLocalACPSessionConfiguration(conversationID: conversation, model: "wanted", thinking: "high")
    let gate = NoncooperatingConfigurationGate()
    let state = FakeGatewayProcess()
    let initial = LocalACPSessionConfiguration(model: stage == "model" ? "initial" : "wanted",
      thinking: "low", modelOptions: ["wanted"], thinkingOptions: ["high"])
    let late = LocalACPSessionConfiguration(model: "late", thinking: "late", thinkingOptions: ["high"])
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      let process = state.launch()
      return LocalACPSessionDriver(initializeSession: { _, _, _, _ in
        LocalACPInitializedSession(sessionID: "fixture", loadedExistingSession: false, configuration: initial)
      }, prompt: { _, _, _, _ in .endTurn }, configuration: { late },
      setConfiguration: { _, _ in await gate.pause(); return late }, cancel: {}, shutdown: { process.terminate() })
    })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
    let start = Task { try await coordinator.configuration(conversationID: conversation, launch: launch, workspace: workspace) }
    await gate.waitForStart()
    let stop: Task<Void, Never>?
    if shutdown { stop = Task { await coordinator.shutdown() } }
    else { start.cancel(); stop = nil }
    await gate.waitForInterruption()
    // The driver deliberately ignores cancellation and returns a successful configuration.
    await gate.release()
    do { _ = try await start.value; Issue.record("interrupted startup returned configuration") } catch { }
    await stop?.value
    #expect(!state.running)
    #expect(await gate.calls == 1)
    let descriptor = try database.localACPSession(conversationID: conversation)
    #expect(descriptor.model == "wanted")
    #expect(descriptor.thinking == "high")
    await coordinator.shutdown()
  }

  private var launch: LocalACPRuntimeLaunchConfiguration {
    LocalACPRuntimeLaunchConfiguration(runtimeKind: .openclaw,
      executableURL: URL(filePath: "/nonexistent-fixture-gateway"), arguments: [])
  }
}

private final class FakeGatewayProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var alive = false, readyValue = false
  private var count = 0
  var running: Bool { lock.withLock { alive } }
  var ready: Bool { lock.withLock { readyValue } }
  var launches: Int { lock.withLock { count } }
  func setReady() { lock.withLock { readyValue = true } }
  func launch() -> OpenClawLocalGatewayLifecycle.OwnedProcess {
    lock.withLock { alive = true; count += 1 }
    return .init(isRunning: { self.running }, terminate: { self.lock.withLock { self.alive = false } })
  }
}

private actor RuntimeGate {
  private var arrivals = 0
  private var blocked: [Int: CheckedContinuation<Void, Never>] = [:]
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  func pause() async {
    let index = arrivals
    arrivals += 1
    await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      blocked[index] = continuation
      let ready = observers.filter { $0.0 <= arrivals }
      observers.removeAll { $0.0 <= arrivals }
      for item in ready { item.1.resume() }
    }
    } onCancel: { Task { await self.release(index) } }
  }
  func waitForArrivals(_ count: Int) async {
    if arrivals >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
  func release(_ index: Int) { blocked.removeValue(forKey: index)?.resume() }
}

private actor NoncooperatingConfigurationGate {
  private(set) var calls = 0
  private var wasInterrupted = false
  private var startObserver: CheckedContinuation<Void, Never>?
  private var interruptionObserver: CheckedContinuation<Void, Never>?
  private var response: CheckedContinuation<Void, Never>?
  func pause() async {
    calls += 1
    guard calls == 1 else { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        response = continuation
        startObserver?.resume()
        startObserver = nil
      }
    } onCancel: { Task { await self.interrupted() } }
  }
  func waitForStart() async {
    if calls > 0 { return }
    await withCheckedContinuation { startObserver = $0 }
  }
  func waitForInterruption() async {
    if wasInterrupted { return }
    await withCheckedContinuation { interruptionObserver = $0 }
  }
  private func interrupted() {
    wasInterrupted = true
    interruptionObserver?.resume()
    interruptionObserver = nil
  }
  func release() { response?.resume(); response = nil }
}
