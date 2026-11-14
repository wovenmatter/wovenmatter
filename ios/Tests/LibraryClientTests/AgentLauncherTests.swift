import XCTest
import WovenMatterShared
@testable import LibraryClient

final class AgentLauncherTests: XCTestCase {
  private let workspaceID = "10000000-0000-0000-0000-000000000001"
  private var workspace: ExecutionWorkspace {
    .init(id: workspaceID, libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Remote")
  }
  private var pi: HarnessCapabilities { .init(id: "pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: true) }

  func testDiscoveredRoutesDeduplicateAndSelectOnlyTheLatestMatchingSession() throws {
    let hostAgent = HarnessCapabilities(id: "remote:" + workspaceID + ":pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)
    func agents(hostOnline: Bool, directOnline: Bool) -> [LaunchableAgent] {
      LaunchableAgent.list(deviceName: "Phone", hostOnline: hostOnline, providers: [hostAgent], workspaces: [workspace],
        workspaceProviders: [workspaceID: [pi]], reachable: [workspaceID: directOnline])
    }
    XCTAssertEqual(agents(hostOnline: true, directOnline: true).map(\.workspaceID), ["local", workspaceID])
    XCTAssertEqual(agents(hostOnline: true, directOnline: false).map(\.workspaceID), ["local", "host"])
    let offline = agents(hostOnline: false, directOnline: false)
    XCTAssertEqual(offline.map(\.workspaceID), ["local", workspaceID])
    XCTAssertFalse(offline[1].isAvailable)
      let launcher = try XCTUnwrap(agents(hostOnline: true, directOnline: true).first { $0.workspaceID == workspaceID })
    let conversations: [LibraryConversation] = [
      .init(id: "pinned", title: "Pinned", providerID: "pi", updatedAt: "2026-10-11T12:00:00Z", isPinned: true),
      .init(id: "latest", title: "Latest", providerID: "pi", updatedAt: "2026-10-11T12:00:00.500Z"),
      .init(id: "other-workspace", title: "Other", providerID: "pi", updatedAt: "2026-10-11T15:00:00Z"),
      .init(id: "other-agent", title: "Other", providerID: "another-pi", runtimeKind: "default_agent", updatedAt: "2026-10-11T16:00:00Z")
    ]
    let latest = launcher.latestConversation(in: conversations) { $0 == "other-workspace" ? "another-workspace" : self.workspaceID }
    XCTAssertEqual(try XCTUnwrap(latest).id, "latest")
    XCTAssertNil(launcher.latestConversation(in: conversations) { _ in "another-workspace" })
  }

  func testLibraryHostMacAppearsOnceByItsNameAndEmptyLinuxWorkspaceRemainsVisible() {
    let mac = ExecutionWorkspace(id: "mac", libraryID: "library", ownerDeviceID: "host", kind: .mac,
      name: "James’s MacBook Air", capabilities: ["history.library.v1"])
    let local = HarnessCapabilities(id: "local:pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)
    let codex = HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)
    let empty = ExecutionWorkspace(id: workspaceID, libraryID: "library", ownerDeviceID: "host", kind: .linux, name: "Test")
    let unconfigured = HarnessCapabilities(id: "remote:" + workspaceID + ":pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: false, canStart: false)
    let agents = LaunchableAgent.list(deviceName: "This iPhone", hostOnline: true,
      providers: [local, codex, unconfigured], workspaces: [mac, empty],
      workspaceProviders: ["mac": [local], workspaceID: []], reachable: ["mac": true], hostWorkspaceID: mac.id)
    XCTAssertEqual(agents.map(\.providerID), ["pi-durable-device", "local:pi", "local:codex"])
    XCTAssertTrue(agents.dropFirst().allSatisfy { $0.workspaceName == mac.name })
    let groups = AgentGroup.list(agents: agents, workspaces: [mac, empty], hostWorkspaceID: mac.id)
    XCTAssertEqual(groups.map(\.name), ["This iPhone", "James’s MacBook Air", "Test"], "Quick Chat leads, then the workspaces")
    XCTAssertEqual(groups.first(where: { $0.name == "Test" })?.agents, [])
    XCTAssertEqual(groups.first(where: { $0.name == "Test" })?.workspace?.kind, .linux)
  }

  /// From a phone paired as a member with two Dev Macs: both serve library
  /// history. The library host's own agent list ("This Mac") belongs to the
  /// library host only, so each Mac is listed once, under its own name, with
  /// its own agents, and Quick Chat leads.
  func testMemberMacsEachAppearOnceUnderTheirOwnNames() {
    let capabilities = ["execution.v1", "history.library.v1", "inference.v1"]
    let air = ExecutionWorkspace(id: "0446435c-8e64-440e-b9eb-3c5dadb27e04", libraryID: "air-library",
      ownerDeviceID: "e775f2b2-1e79-4bc2-b723-39b3fab2d9c5", kind: .mac, name: "James’s MacBook Air (Dev) · worktrees-b8e80bfb02",
      endpoint: URL(string: "https://air.example.ts.net/wovenmatter"), capabilities: capabilities)
    let mini = ExecutionWorkspace(id: "b03923c3-89d1-4f29-910a-b7e3ce7b586c", libraryID: "mini-library",
      ownerDeviceID: "7c072eba-eb7c-490b-9434-fb710c7f828f", kind: .mac, name: "James’s Mac Mini (Dev) · woven-everywhere",
      endpoint: URL(string: "https://mini.example.ts.net/wovenmatter"), capabilities: capabilities)
    let copied = ExecutionWorkspace(id: "3407decc-357c-4d96-a209-92be30520fb6", libraryID: "air-library",
      ownerDeviceID: "old", kind: .mac, name: "James’s MacBook Air", capabilities: capabilities, retainedHistory: true)
    func agent(_ kind: String, ready: Bool) -> HarnessCapabilities {
      .init(id: "local:" + kind, runtimeKind: kind, displayName: kind, available: ready, canStart: ready)
    }
    let ready = [agent("default_agent", ready: true), agent("codex", ready: true), agent("claude_code", ready: true)]
    // A stale host list from the library host still lists Codex as needing setup.
    let hostList = [agent("default_agent", ready: true), agent("codex", ready: false), agent("claude_code", ready: true)]
    for order in [[mini, air, copied], [air, copied, mini]] {
      let agents = LaunchableAgent.list(deviceName: "This iPhone", hostOnline: true, providers: hostList,
        workspaces: order, workspaceProviders: [air.id: ready, mini.id: ready, copied.id: ready],
        reachable: [air.id: true, mini.id: true], hostWorkspaceID: air.id)
      let groups = AgentGroup.list(agents: agents.filter { $0.workspaceID != copied.id }, workspaces: order, hostWorkspaceID: air.id)
      XCTAssertEqual(groups.map(\.name), ["This iPhone", air.name, mini.name])
      XCTAssertEqual(groups.map(\.id), ["local", "host", mini.id])
      XCTAssertEqual(groups[1].workspace?.id, air.id)
      XCTAssertEqual(groups[2].workspace?.id, mini.id)
      // The library host's own agents: the host route, or its direct route when the host entry is not ready.
      XCTAssertEqual(groups[1].agents.map(\.workspaceID), ["host", "host", air.id])
      XCTAssertEqual(groups[1].agents.map(\.providerID), ["local:default_agent", "local:claude_code", "local:codex"])
      XCTAssertTrue(groups[1].agents.allSatisfy(\.isAvailable), "A stale host entry falls back to the Mac's own fresh list")
      XCTAssertEqual(groups[2].agents.map(\.workspaceID), [mini.id, mini.id, mini.id])
      XCTAssertTrue(groups[2].agents.allSatisfy { $0.workspaceName == mini.name })
    }
  }

  func testCopiedSnapshotOwnerNeverNamesOrBecomesTheLibraryHost() {
    // A snapshot keeps its source Mac's workspace as retained history, with the same capability.
    let copied = ExecutionWorkspace(id: "copied", libraryID: "library", ownerDeviceID: "source", kind: .mac,
      name: "Mac Mini (Dev) · source", capabilities: ["history.library.v1"], retainedHistory: true)
    let live = ExecutionWorkspace(id: "live", libraryID: "library", ownerDeviceID: "host", kind: .mac,
      name: "Mac Mini (Dev) · e2e", capabilities: ["history.library.v1"])
    let local = HarnessCapabilities(id: "local:pi", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)
    for order in [[copied, live], [live, copied]] {
      XCTAssertNil(ExecutionWorkspace.liveLibraryMac(in: order, id: copied.id), "A copy is never the library host")
      let agents = LaunchableAgent.list(deviceName: "This iPhone", hostOnline: true, providers: [local],
        workspaces: order, workspaceProviders: [:], reachable: [:], hostWorkspaceID: live.id)
      XCTAssertEqual(agents.last?.workspaceName, live.name)
      let groups = AgentGroup.list(agents: agents, workspaces: order, hostWorkspaceID: live.id)
      XCTAssertEqual(groups.map(\.name), ["This iPhone", live.name])
      XCTAssertEqual(groups.last?.workspace?.id, live.id)
    }
  }

}
