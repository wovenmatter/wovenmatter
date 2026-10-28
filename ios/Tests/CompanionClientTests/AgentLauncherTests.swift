import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class AgentLauncherTests: XCTestCase {
  private let workspaceID = "10000000-0000-0000-0000-000000000001"
  private var workspace: CompanionExecutionWorkspace {
    .init(id: workspaceID, libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Remote")
  }
  private var pi: CompanionProvider { .init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true) }

  func testDiscoveredRoutesDeduplicateAndSelectOnlyTheLatestMatchingSession() throws {
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
      let launcher = try XCTUnwrap(agents(centralOnline: true, directOnline: true).first { $0.workspaceID == workspaceID })
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
    XCTAssertTrue(agents.dropFirst().allSatisfy { $0.workspaceName == mac.name })
    let groups = CompanionAgentGroup.list(agents: agents, workspaces: [mac, empty])
    XCTAssertEqual(groups.map(\.name), ["James’s MacBook Air", "Test", "This iPhone"])
    XCTAssertEqual(groups.first(where: { $0.name == "Test" })?.agents, [])
    XCTAssertEqual(groups.first(where: { $0.name == "Test" })?.workspace?.kind, .linux)
  }

}
