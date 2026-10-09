import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Built-in Durable run lifecycle", .timeLimit(.minutes(1)))
struct BuiltInDurableLifecycleTests {
  private func launch() -> LocalACPRuntimeLaunchConfiguration {
    .init(runtimeKind: .defaultAgent, executableURL: URL(fileURLWithPath: "/fixture"), arguments: [])
  }

  @Test(arguments: ["configuration", "prompt", "nextPrompt", "shutdown"])
  func backgroundWorkRetainsOneOwnerUntilIdleOrShutdown(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wm-durable-idle-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try await database.createLocalACPSession(runtimeKind: .defaultAgent,
      title: "Background fixture", ownerDeviceID: UUID())
    let lease = ConfigurationTestProcessLease(), client = BackgroundDriverFixture()
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: lease,
      clientFactory: { _, _ in client.driver() })
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
    if mode == "prompt" || mode == "nextPrompt" {
      _ = try await coordinator.accept(conversationID: conversation, content: "Primary input",
        launch: launch(), workspace: workspace)
    } else {
      _ = try await coordinator.configuration(conversationID: conversation, launch: launch(), workspace: workspace)
    }
    await client.waitUntilIdleRequested()
    #expect(lease.snapshot.holds == 1)
    #expect(await client.shutdownCount == 0)
    if mode == "prompt" || mode == "nextPrompt" {
      #expect(try await database.conversationContent(id: conversation).runs.first?.status == "completed")
    }
    if mode == "nextPrompt" {
      _ = try await coordinator.accept(conversationID: conversation, content: "Next input",
        launch: launch(), workspace: workspace)
      for _ in 0..<100 {
        if try await database.conversationContent(id: conversation).runs.filter({ $0.status == "completed" }).count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(try await database.conversationContent(id: conversation).runs.filter { $0.status == "completed" }.count == 2)
      #expect(await client.promptCount == 2)
    } else if mode != "shutdown" {
      _ = try await coordinator.configuration(conversationID: conversation, launch: launch(), workspace: workspace)
    }
    #expect(await client.initializeCount == 1)
    #expect(await client.idleRequestCount == 1)
    #expect(await client.shutdownCount == 0)
    #expect(lease.snapshot.holds == 1)
    if mode == "shutdown" { await coordinator.shutdown() }
    else { await client.finishBackgroundWork() }
    for _ in 0..<100 where lease.snapshot.holds != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(lease.snapshot.holds == 0)
    #expect(await client.shutdownCount == 1)
    await coordinator.shutdown()
  }

  @Test(arguments: [false, true])
  func transportFailurePreservesOnlyDispatchedNativeWork(dispatched: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wm-durable-dispatch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try await database.createLocalACPSession(runtimeKind: .defaultAgent,
      title: "Dispatch fixture", ownerDeviceID: UUID())
    let configuration = LocalACPSessionConfiguration(permission: "full", permissionOptions: ["full"])
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, _, _, _ in
          .init(sessionID: "native", loadedExistingSession: false, configuration: configuration)
        }, prompt: { _, _, _, _ in throw LocalACPClientError.processExited },
        configuration: { configuration }, setConfiguration: { _, _ in configuration }, cancel: {}, shutdown: {},
        fencedPrompt: { _, _, _, _, fence in
          if dispatched { try fence.claimDispatch() }
          throw LocalACPClientError.processExited
        })
    })
    _ = try await coordinator.accept(conversationID: conversation, content: "Committed work",
      launch: launch(), workspace: .init(rootURL: directory, repositoriesURL: directory))
    for _ in 0..<100 {
      if let status = try await database.conversationContent(id: conversation).runs.first?.status,
         ["failed", "uncertain"].contains(status) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let status = try await database.conversationContent(id: conversation).runs.first?.status
    #expect(status == (dispatched ? "uncertain" : "failed"))
    if dispatched {
      await #expect(throws: LocalACPSessionDatabaseError.runAlreadyActive) {
        try await database.beginLocalACPRun(conversationID: conversation, content: "Duplicate")
      }
    }
    await coordinator.shutdown()
  }
}

private actor BackgroundDriverFixture {
  private let started = AsyncStream<Void>.makeStream()
  private var idleWaiter: CheckedContinuation<Void, Never>?
  var shutdownCount = 0
  var idleRequestCount = 0
  var initializeCount = 0
  var promptCount = 0
  nonisolated func driver() -> LocalACPSessionDriver {
    let configuration = LocalACPSessionConfiguration(permission: "full", permissionOptions: ["full"])
    return LocalACPSessionDriver(initializeSession: { _, existing, _, _ in
        await self.initialize(existing: existing, configuration: configuration)
      }, prompt: { _, event, _, _ in try await self.prompt(event: event) },
      configuration: { configuration }, setConfiguration: { _, _ in configuration }, cancel: {},
      shutdown: { await self.shutdown() }, awaitIdle: { await self.awaitIdle() })
  }
  private func initialize(existing: String?, configuration: LocalACPSessionConfiguration) -> LocalACPInitializedSession {
    initializeCount += 1
    return .init(sessionID: existing ?? "native", loadedExistingSession: existing != nil, configuration: configuration)
  }
  private func prompt(event: LocalACPClient.EventHandler?) async throws -> LocalACPStopReason {
    promptCount += 1
    try await event?(.assistantChunk("Primary result"))
    return .endTurn
  }
  private func awaitIdle() async {
    idleRequestCount += 1
    await withCheckedContinuation { continuation in
      idleWaiter = continuation
      started.continuation.yield(())
    }
  }
  func waitUntilIdleRequested() async { for await _ in started.stream { break } }
  func finishBackgroundWork() { idleWaiter?.resume(); idleWaiter = nil }
  private func shutdown() { shutdownCount += 1; finishBackgroundWork() }
}
