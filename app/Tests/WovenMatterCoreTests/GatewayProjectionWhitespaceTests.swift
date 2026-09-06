import Testing
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct GatewayProjectionWhitespaceTests {
  @Test func assistantDeltasMatchSnapshots() {
    let chunks = ["  hello", " ", "world\n", "\t"]
    let text = chunks.joined()
    let projected = chunks.compactMap { chunk -> String? in
      let result = project("agent", ["stream": .string("assistant"), "data": .object(["delta": .string(chunk)])])
      if case .append(let value) = result?.assistantUpdate { return value }
      return nil
    }.joined()
    #expect(projected == text)
    #expect(project("agent", ["stream": .string("assistant"), "data": .object(["text": .string(text)])])?.assistantUpdate == .replace(text))
    #expect(project("chat", ["deltaText": .string(" \n")])?.assistantUpdate == .append(" \n"))
    #expect(project("chat", ["message": .object(["text": .string(text)])])?.assistantUpdate == .replace(text))
    #expect(project("chat", ["message": .object(["text": .string("")])])?.assistantUpdate == .replace(""))
  }

  @Test func activityContentIsLosslessAndIDsAreNormalized() {
    let text = "  output\n\t"
    let tool = project("agent", ["runId": .string(" run "), "stream": .string("tool"), "data": .object([
      "toolCallId": .string(" tool "), "name": .string(" exec "), "result": .string(text),
    ])])
    #expect(tool?.runID == "run")
    #expect(tool?.activity?.id == "tool")
    #expect(tool?.activity?.toolName == "exec")
    #expect(tool?.activity?.content == text)
    for chunk in [" hello ", " \n", "\t"] {
      #expect(project("agent", ["stream": .string("thinking"), "data": .object(["delta": .string(chunk)])])?.activity?.content == chunk)
      #expect(project("agent", ["stream": .string("command_output"), "data": .object(["output": .string(chunk)])])?.activity?.content == chunk)
    }
  }

  private func project(_ name: String, _ payload: [String: GatewayJSONValue]) -> OpenClawGatewayEventProjection? {
    OpenClawGatewayEventProjection.project(OpenClawGatewayEvent(name: name, payload: .object(payload), sequence: 1))
  }
}
