import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPResumePermissionTests {
  @Test(arguments: [AgentRuntimeKind.defaultAgent, .codex, .pi], [false, true])
  func configurationLoadsRouteDurableApprovalsToTheirConversation(runtime: AgentRuntimeKind, remote: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversations = try (0..<2).map { index in
      let id = try remote
        ? database.createRemoteACPSession(runtimeKind: runtime, remoteWorkspaceID: UUID(),
            remoteWorkspaceName: "Fixture", title: "Resume \(index)", ownerDeviceID: UUID())
        : database.createLocalACPSession(runtimeKind: runtime, title: "Resume \(index)", ownerDeviceID: UUID())
      try database.updateLocalACPSessionID(conversationID: id, sessionID: "remote-\(index)")
      return id
    }
    let requests = ResumePermissionRecorder()
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      ResumePermissionDriver(expectsHandler: runtime == .defaultAgent || remote).driver()
    })
    await coordinator.setResumePermissionHandler { conversationID, request in
      await requests.record(conversationID: conversationID, title: request.title)
      return "allow_once"
    }
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: runtime, executableURL: URL(filePath: "/nonexistent-resume-fixture"), arguments: []
    )
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)

    // A configuration refresh can load an active remote run before a prompt
    // supplies its own handler. Each concurrent load must keep its identity.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in conversations {
        group.addTask {
          _ = try await coordinator.configuration(conversationID: id, launch: launch, workspace: workspace)
        }
      }
      try await group.waitForAll()
    }

    let observed = await requests.values
    if runtime == .defaultAgent || remote {
      #expect(observed == [conversations[0]: "remote-0", conversations[1]: "remote-1"])
    } else {
      #expect(observed.isEmpty)
    }
    await coordinator.shutdown()
  }
}

private actor ResumePermissionRecorder {
  private(set) var values: [String: String] = [:]

  func record(conversationID: String, title: String) {
    values[conversationID] = title
  }
}

private actor ResumePermissionDriver {
  private let expectsHandler: Bool
  private var handler: LocalACPClient.PermissionHandler?

  init(expectsHandler: Bool) { self.expectsHandler = expectsHandler }

  nonisolated func driver() -> LocalACPSessionDriver {
    LocalACPSessionDriver(
      initializeSession: { _, existing, _, _ in try await self.load(existing) },
      prompt: { _, _, _, _ in
        Issue.record("Reattaching a remote approval must not send a new prompt")
        return .endTurn
      },
      configuration: { .empty },
      setConfiguration: { _, _ in .empty },
      cancel: {},
      shutdown: {},
      setResumePermissionHandler: { await self.setHandler($0) }
    )
  }

  private func setHandler(_ value: @escaping LocalACPClient.PermissionHandler) {
    handler = value
  }

  private func load(_ existing: String?) async throws -> LocalACPInitializedSession {
    let id = try #require(existing)
    if expectsHandler {
      let handler = try #require(handler)
      let response = await handler(LocalACPPermissionRequest(title: id, options: [
        LocalACPPermissionOption(id: "allow_once", name: "Allow once", kind: "allow_once"),
      ]))
      #expect(response == "allow_once")
    } else {
      #expect(handler == nil)
    }
    return LocalACPInitializedSession(sessionID: id, loadedExistingSession: true)
  }
}
