import Testing
@testable import WovenMatterClient

struct PiStreamingActivityTests {
  @Test func toolLifecycleRetainsInputsPartialAndFinalOutput() throws {
    guard case .activity(let start, _) = PiRPCClient.event(from: [
      "type": "tool_execution_start", "toolCallId": "t", "toolName": "read", "args": ["path": "fixture.txt"]
    ]) else { Issue.record("Missing start"); return }
    guard case .activity(let update, _) = PiRPCClient.event(from: [
      "type": "tool_execution_update", "toolCallId": "t", "partialResult": ["content": [["type": "text", "text": "partial\n"]]]
    ]) else { Issue.record("Missing update"); return }
    guard case .activity(let end, _) = PiRPCClient.event(from: [
      "type": "tool_execution_end", "toolCallId": "t", "isError": true,
      "result": ["content": [["type": "text", "text": "final\n"]]]
    ]) else { Issue.record("Missing result"); return }
    let activity = start.merging(update).merging(end)
    #expect(activity.id == "t")
    #expect(activity.rawInputJSON == "{\"path\":\"fixture.txt\"}")
    #expect(activity.content == "final\n")
    #expect(activity.status == "failed")
    #expect(activity.rawOutputJSON?.contains("final") == true)
  }
}
