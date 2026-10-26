import Testing
@testable import WovenMatterCore

struct RuntimeInspectionInventoryTests {
  typealias Item = RuntimeInspection.Item

  @Test func connectionHelpersAreSeparateFromAgentsRegardlessOfExecutableNames() {
    let items: [Item] = [
      .init(id: "server", kind: "service", title: "Server", state: "running"),
      .init(id: "helper", parentID: "server", kind: "connectionSupervisor", title: "Woven Matter", state: "running", processID: 2),
      .init(id: "transport", parentID: "helper", kind: "connectionProcess", title: "Tailscale", state: "running", processID: 3),
      .init(id: "agent", parentID: "server", conversationID: "chat-a", kind: "runtime", title: "Tailscale", state: "running", processID: 4),
      .init(id: "chat", parentID: "server", conversationID: "chat-a", kind: "conversation", title: "Research", state: "working"),
    ]
    let view = RuntimeInspectionInventory(items: items)
    #expect(view.connections.map(\.processID) == [2, 3])
    #expect(view.agents.count == 1)
    #expect(view.agents[0].summary.title == "Research")
    #expect(view.agents[0].details.map(\.processID) == [4])
    #expect(view.otherProcesses.isEmpty)
  }

  @Test func chatOwnershipKeepsAgentDescendantsWithTheirOwnChat() {
    let view = RuntimeInspectionInventory(items: [
      .init(id: "a", conversationID: "a", kind: "conversation", title: "A", state: "working"),
      .init(id: "b", conversationID: "b", kind: "conversation", title: "B", state: "working"),
      .init(id: "runtime-a", parentID: "a", kind: "runtime", title: "Codex", state: "running", processID: 10),
      .init(id: "runtime-b", parentID: "b", kind: "runtime", title: "Codex", state: "running", processID: 20),
      .init(id: "shell", parentID: "runtime-a", kind: "process", title: "bash", state: "running", processID: 11),
      .init(id: "child", conversationID: "b", kind: "subagent", title: "Reviewer", state: "working"),
    ])
    #expect(view.agents.count == 2)
    #expect(Set(view.agents[0].details.map(\.id)) == ["runtime-a", "shell"])
    #expect(Set(view.agents[1].details.map(\.id)) == ["runtime-b", "child"])
  }

  @Test func remoteNativeBindingsKeepSharedWorkersSeparateFromLogicalChildren() {
    var first = Item(id: "first", parentID: "worker", kind: "conversation", title: "First", state: "working")
    first.nativeSessionID = "native-a"
    var second = Item(id: "second", parentID: "worker", kind: "conversation", title: "Second", state: "working")
    second.nativeSessionID = "native-b"
    var task = Item(id: "task", parentID: "second", kind: "subagent", title: "Researcher", state: "waiting")
    task.nativeSessionID = "native-b"
    let view = RuntimeInspectionInventory(items: [first, second, task,
      .init(id: "worker", kind: "runtime", title: "Shared Pi runtime", state: "running", processID: 30)])
    #expect(view.agents.count == 3)
    #expect(view.agents.first { $0.summary.id == "first" }?.details.isEmpty == true)
    #expect(view.agents.first { $0.summary.id == "second" }?.details.map(\.id) == ["task"])
    #expect(view.agents.first { $0.summary.id == "worker" }?.summary.processID == 30)
  }

  @Test func unknownAndCyclicParentageRemainsInspectableWithoutGuessingOwnership() {
    let view = RuntimeInspectionInventory(items: [
      .init(id: "a", parentID: "b", kind: "process", title: "A", state: "running"),
      .init(id: "b", parentID: "a", kind: "process", title: "B", state: "running"),
      .init(id: "orphan", parentID: "missing", kind: "process", title: "Unknown", state: "running"),
    ])
    #expect(view.agents.isEmpty)
    #expect(view.connections.isEmpty)
    #expect(view.otherProcesses.count == 3)
  }
}
