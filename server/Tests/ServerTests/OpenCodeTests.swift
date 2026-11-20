import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

/// A turn as OpenCode streams it, split at awkward places, becomes text, one
/// finished tool call and a finished turn with the steps' usage added up.
@Test func openCodeTurnBecomesRuntimeEvents() {
  let frames = [
    #"{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1","model":{"id":"big","providerID":"p"}}}"#,
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"read"}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":{"path":"."}}}"#,
    #"{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","content":[{"type":"text","text":"a.txt"}]}}"#,
    #"{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"m1","cost":0.5,"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":0}}}}"#,
    #"{"type":"session.text.started","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"delta":"Files: "}}"#,
    #"{"type":"session.text.ended","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"text":"Files: a.txt"}}"#,
    #"{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"m2","cost":0.25,"tokens":{"input":5,"output":4,"reasoning":0,"cache":{"read":1,"write":2}}}}"#,
    #"{"type":"session.execution.succeeded","data":{"sessionID":"s"}}"#,
  ]
  let stream = Data(frames.map { "data: \($0)\r\n\r\n" }.joined().utf8)
  var parser = OpenCodeSSEParser()
  var projection = OpenCodeProjection()
  var events: [RuntimeEvent] = []
  for start in stride(from: 0, to: stream.count, by: 7) {
    for event in parser.append(stream.subdata(in: start..<min(start + 7, stream.count))) {
      events += projection.receive(event)
    }
  }

  var text = ""
  var finishedCalls: [ToolCall] = []
  var turn: (failure: String?, usage: TokenUsage?)?
  for event in events {
    switch event {
    case .text(let delta): text += delta
    case .tool(_, let call, true): finishedCalls.append(call)
    case .turnFinished(let failure, let usage): turn = (failure, usage)
    default: break
    }
  }
  #expect(text == "Files: a.txt")
  #expect(finishedCalls == [ToolCall(name: "read", input: #"{"path":"."}"#, output: "a.txt", title: ".", kind: .read)])
  #expect(turn?.failure == nil)
  #expect(turn?.usage == TokenUsage(model: "p/big", input: 15, output: 7, cacheRead: 4, cacheWrite: 2, cost: 0.75))
}
