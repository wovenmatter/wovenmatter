import WorkspaceFixtures
import Darwin
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

struct RuntimeLifecycleTests {
  @Test func cancelledACPStartupShutsDriverDownAndAllowsRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "fixture", ownerDeviceID: UUID())
    let gate = RuntimeGate()
    let state = FakeRuntimeProcess()
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
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory)
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

private final class FakeRuntimeProcess: @unchecked Sendable {
  struct Handle: Sendable { let terminate: @Sendable () -> Void }
  private let lock = NSLock()
  private var alive = false
  private var count = 0
  var running: Bool { lock.withLock { alive } }
  var launches: Int { lock.withLock { count } }
  func launch() -> Handle {
    lock.withLock { alive = true; count += 1 }
    return Handle(terminate: { self.lock.withLock { self.alive = false } })
  }
}
