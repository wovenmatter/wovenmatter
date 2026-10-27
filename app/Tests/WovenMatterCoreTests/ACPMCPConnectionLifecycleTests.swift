import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("ACP MCP connection ownership", .timeLimit(.minutes(1)))
struct ACPMCPConnectionLifecycleTests {
  @Test(arguments: [false, true])
  func inputWaitsForFullRetirementAndRebindsOnlyItsTransport(hasContext: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .defaultAgent, title: "MCP lifecycle", ownerDeviceID: UUID())
    let registry = MCPRetirementFixture(), lease = ConfigurationTestProcessLease()
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: lease, clientFactory: { launch, _ in
      LocalACPSessionDriver(initializeSession: { _, existing, _, _ in
        await registry.initialized(launch.mcpConnection)
        return .init(sessionID: existing ?? "native", loadedExistingSession: existing != nil)
      }, prompt: { input, _, _, _ in
        await registry.received(input)
        return .endTurn
      }, configuration: { .empty }, setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: {})
    })
    await coordinator.setMCPConnectionProvider(onRelease: { await registry.release($0) }) {
      await registry.connection($0)
    }
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .defaultAgent, executableURL: URL(filePath: "/nonexistent-mcp-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory)
    let metadata = Task { try await coordinator.configuration(conversationID: id, launch: launch, workspace: workspace) }
    await registry.waitForRelease()
    // Capture while the previous metadata client has exited but credential
    // cleanup is still awaiting another actor, matching normal new-chat routing.
    let transport = await registry.connection(id)
    let captured = WovenMCPConnection(endpointURL: transport.endpointURL, bearerToken: transport.bearerToken,
      captureID: "immutable-input-capture", sessionID: id)
    _ = try await coordinator.accept(conversationID: id,
      input: .init(text: "Prompt", mcpContext: hasContext ? captured : nil), launch: launch, workspace: workspace)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await registry.initializedConnections.count == 1)
    #expect(await registry.inputs.isEmpty)
    await registry.finishRelease()
    _ = try await metadata.value
    for _ in 0..<500 {
      if lease.snapshot.holds == 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(lease.snapshot.holds == 0)
    let input = try #require(await registry.inputs.first)
    #expect(await registry.inputs.count == 1)
    let initialized = try #require(await registry.initializedConnections.last ?? nil)
    if hasContext {
      let refreshed = try #require(input.mcpContext)
      #expect(refreshed.bearerToken != captured.bearerToken)
      #expect(refreshed.endpointURL != captured.endpointURL)
      #expect(refreshed.bearerToken == initialized.bearerToken)
      #expect(refreshed.endpointURL == initialized.endpointURL)
      #expect(refreshed.captureID == captured.captureID)
      #expect(refreshed.sessionID == captured.sessionID)
      #expect(await registry.promptUsedCurrentCredential == true)
    } else {
      #expect(input.mcpContext == nil)
    }
    #expect(await registry.releases == 2)
    await coordinator.shutdown()
  }

  @Test(arguments: [false, true])
  func rebindingRejectsAnotherConversation(forgedProvider: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .defaultAgent, title: "Scoped MCP", ownerDeviceID: UUID())
    let lease = ConfigurationTestProcessLease()
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: lease, clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, _, _, _ in .init(sessionID: "native", loadedExistingSession: false) },
        prompt: { _, _, _, _ in Issue.record("A different conversation's context reached the harness"); return .endTurn },
        configuration: { .empty }, setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: {})
    })
    await coordinator.setMCPConnectionProvider { requested in
      #expect(requested == id)
      return .init(endpointURL: "http://127.0.0.1:40000/mcp", bearerToken: "fixture", sessionID: forgedProvider ? "different" : id)
    }
    let run = try await coordinator.accept(conversationID: id,
      input: .init(text: "Prompt", mcpContext: .init(endpointURL: "http://127.0.0.1:40000/mcp", bearerToken: "fixture",
        captureID: "capture", sessionID: forgedProvider ? id : "different")),
      launch: .init(runtimeKind: .defaultAgent, executableURL: URL(filePath: "/nonexistent-mcp-fixture"), arguments: []), workspace: .init(rootURL: directory))
    for _ in 0..<500 {
      if lease.snapshot.holds == 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(lease.snapshot.holds == 0)
    let rows = try await database.conversationContent(id: id).runs
    #expect(rows.first(where: { $0.id == run.runID })?.status == "failed")
    await coordinator.shutdown()
  }
}

private actor MCPRetirementFixture {
  private let releaseEntered = AsyncStream<Void>.makeStream()
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var current: WovenMCPConnection?
  private var generation = 0
  var initializedConnections: [WovenMCPConnection?] = []
  var inputs: [AgentMessageInput] = []
  var promptUsedCurrentCredential = false
  var releases = 0
  func connection(_ id: String) -> WovenMCPConnection {
    if let current { return current }
    generation += 1
    let value = WovenMCPConnection(endpointURL: "http://127.0.0.1:\(40000 + generation)/mcp",
      bearerToken: "fixture-generation-\(generation)", sessionID: id)
    current = value
    return value
  }
  func initialized(_ connection: WovenMCPConnection?) { initializedConnections.append(connection) }
  func received(_ input: AgentMessageInput) {
    inputs.append(input)
    promptUsedCurrentCredential = input.mcpContext?.bearerToken == current?.bearerToken
  }
  func release(_ id: String) async {
    releases += 1
    if releases == 1 {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        releaseEntered.continuation.yield(())
      }
    }
    current = nil
  }
  func waitForRelease() async { for await _ in releaseEntered.stream { break } }
  func finishRelease() { releaseWaiter?.resume(); releaseWaiter = nil }
}
