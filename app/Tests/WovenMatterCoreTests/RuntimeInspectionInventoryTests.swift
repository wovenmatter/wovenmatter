import Testing
@testable import WovenMatterCore

struct RuntimeInspectionInventoryTests {
  typealias Item = RuntimeInspection.Item

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

}
