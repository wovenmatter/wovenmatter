import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class AgentLauncherTests: XCTestCase {
  private let workspaceID = "10000000-0000-0000-0000-000000000001"
  private var workspace: CompanionExecutionWorkspace {
    .init(id: workspaceID, libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Remote")
  }
  private var pi: CompanionProvider { .init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true) }

  func testOfflineDiscoveryRemainsVisibleWithoutRestoringReachability() throws {
    let catalog = CompanionAgentCatalog(libraryID: "library", providers: [pi], workspaceProviders: [workspaceID: [pi]], knownAgentIDs: [])
    let restored = try JSONDecoder().decode(CompanionAgentCatalog.self, from: JSONEncoder().encode(catalog))
    let agents = CompanionAgentLauncher.list(deviceName: "This iPhone", centralOnline: false, providers: restored.providers,
      workspaces: [workspace], workspaceProviders: restored.workspaceProviders, reachable: [:])
    XCTAssertEqual(agents.map(\.workspaceID), ["local", "central", workspaceID])
    XCTAssertEqual(agents.map(\.isAvailable), [true, false, false])
  }

  func testPreviouslyConfiguredAgentStaysVisibleWhenServerReportsUnavailable() {
    var unavailable = pi; unavailable.available = false; unavailable.canStart = false
    let neverConfigured = CompanionProvider(id: "unconfigured", runtimeKind: "other", displayName: "Other", available: false, canStart: false)
    let agents = CompanionAgentLauncher.list(deviceName: "Phone", centralOnline: true, providers: [unavailable, neverConfigured],
      workspaces: [], workspaceProviders: [:], reachable: [:], knownAgentIDs: ["central:pi"])
    XCTAssertEqual(agents.map(\.providerID), ["pi-durable-device", "pi"])
    XCTAssertFalse(agents[1].isAvailable)
  }

  func testDirectAndCentralRoutesAppearOnceAndUseReachableRoute() {
    let central = CompanionProvider(id: "remote:" + workspaceID + ":pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)
    func agents(centralOnline: Bool, directOnline: Bool) -> [CompanionAgentLauncher] {
      CompanionAgentLauncher.list(deviceName: "Phone", centralOnline: centralOnline, providers: [central], workspaces: [workspace],
        workspaceProviders: [workspaceID: [pi]], reachable: [workspaceID: directOnline])
    }
    XCTAssertEqual(agents(centralOnline: true, directOnline: true).map(\.workspaceID), ["local", workspaceID])
    XCTAssertEqual(agents(centralOnline: true, directOnline: false).map(\.workspaceID), ["local", "central"])
    let offline = agents(centralOnline: false, directOnline: false)
    XCTAssertEqual(offline.map(\.workspaceID), ["local", workspaceID])
    XCTAssertFalse(offline[1].isAvailable)
  }

  func testCentralMacAppearsOnceByItsNameAndEmptyLinuxWorkspaceRemainsVisible() {
    let mac = CompanionExecutionWorkspace(id: "mac", libraryID: "library", ownerDeviceID: "host", kind: .mac,
      name: "James’s MacBook Air", capabilities: ["history.central.v1"])
    let local = CompanionProvider(id: "local:pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)
    let gateway = CompanionProvider(id: "gateway:eddie", runtimeKind: "openclaw", displayName: "Eddie", routeName: "OpenClaw Gateway", available: true)
    let empty = CompanionExecutionWorkspace(id: workspaceID, libraryID: "library", ownerDeviceID: "host", kind: .linux, name: "Test")
    let unconfigured = CompanionProvider(id: "remote:" + workspaceID + ":pi", runtimeKind: "pi", displayName: "Pi Durable", available: false, canStart: false)
    let agents = CompanionAgentLauncher.list(deviceName: "This iPhone", centralOnline: true,
      providers: [local, gateway, unconfigured], workspaces: [mac, empty],
      workspaceProviders: ["mac": [local], workspaceID: []], reachable: ["mac": true])
    XCTAssertEqual(agents.map(\.providerID), ["pi-durable-device", "local:pi", "gateway:eddie"])
    XCTAssertTrue(agents.dropFirst().allSatisfy { $0.isLocalMac && $0.workspaceName == mac.name })
    let groups = CompanionAgentGroup.list(agents: agents, workspaces: [mac, empty])
    XCTAssertEqual(groups.map(\.name), ["This iPhone", "James’s MacBook Air", "Test"])
    XCTAssertEqual(groups.last?.agents, [])
    XCTAssertEqual(groups.last?.workspace?.kind, .linux)
  }

  func testMacRouteFallbackDoesNotDuplicateOrLoseItsLatestSession() throws {
    let mac = CompanionExecutionWorkspace(id: "mac", libraryID: "library", ownerDeviceID: "host", kind: .mac,
      name: "MacBook Air", capabilities: ["history.central.v1"])
    let local = CompanionProvider(id: "local:pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)
    let agents = CompanionAgentLauncher.list(deviceName: "Phone", centralOnline: false, providers: [local], workspaces: [mac],
      workspaceProviders: ["mac": [local]], reachable: ["mac": true])
    let agent = try XCTUnwrap(agents.last)
    XCTAssertEqual(agents.count, 2); XCTAssertEqual(agent.workspaceID, "mac")
    XCTAssertTrue(agent.isLocalMac && agent.isAvailable)
    let conversations = [CompanionConversation(id: "old-central", title: "Earlier", providerID: "local:pi", updatedAt: "2026-10-14T12:00:00Z"),
      CompanionConversation(id: "new-direct", title: "Latest", providerID: "local:pi", updatedAt: "2026-10-14T13:00:00Z")]
    let latest = agent.latestConversation(in: conversations) { $0 == "old-central" ? "central" : "mac" }
    XCTAssertEqual(latest?.id, "new-direct")
    let centralOnly = agent.latestConversation(in: Array(conversations.prefix(1))) { _ in "central" }
    XCTAssertEqual(centralOnly?.id, "old-central")
  }

  func testIdenticalHarnessesOnTwoMacsRemainDistinctAndDeletedWorkspacesStayHidden() {
    let primary = CompanionExecutionWorkspace(id: "primary", libraryID: "library", ownerDeviceID: "host", kind: .mac,
      name: "MacBook Air", capabilities: ["history.central.v1"])
    let secondary = CompanionExecutionWorkspace(id: "secondary", libraryID: "library", ownerDeviceID: "other", kind: .mac, name: "Mac mini")
    let deleted = CompanionExecutionWorkspace(id: "deleted", libraryID: "library", ownerDeviceID: "host", kind: .linux, name: "Removed", deleted: true)
    let local = CompanionProvider(id: "local:pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)
    let workspaces = [primary, secondary, deleted]
    let agents = CompanionAgentLauncher.list(deviceName: "Phone", centralOnline: true, providers: [local], workspaces: workspaces,
      workspaceProviders: ["primary": [local], "secondary": [local]], reachable: ["primary": true, "secondary": true])
    XCTAssertEqual(agents.map(\.workspaceID), ["local", "central", "secondary"])
    XCTAssertEqual(CompanionAgentGroup.list(agents: agents, workspaces: workspaces).map(\.id), ["local", "central", "secondary"])
  }

  func testLatestSessionUsesExactOwnerAndProviderIgnoringPinsAndTimestampFormatting() throws {
    let launcher = CompanionAgentLauncher(workspaceID: workspaceID, workspaceName: "Remote", providerID: "pi", name: "Pi Durable", runtimeKind: "pi")
    let conversations: [CompanionConversation] = [
      .init(id: "pinned", title: "Pinned", providerID: "pi", updatedAt: "2026-10-11T12:00:00Z", isPinned: true),
      .init(id: "latest", title: "Latest", providerID: "pi", updatedAt: "2026-10-11T12:00:00.500Z"),
      .init(id: "other-workspace", title: "Other", providerID: "pi", updatedAt: "2026-10-11T15:00:00Z"),
      .init(id: "other-agent", title: "Other", providerID: "another-pi", runtimeKind: "pi", updatedAt: "2026-10-11T16:00:00Z")
    ]
    let latest = launcher.latestConversation(in: conversations) { $0 == "other-workspace" ? "another-workspace" : self.workspaceID }
    XCTAssertEqual(try XCTUnwrap(latest).id, "latest")
    XCTAssertNil(launcher.latestConversation(in: conversations) { _ in "another-workspace" })
  }
}
