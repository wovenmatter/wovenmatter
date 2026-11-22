import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

/// A turn as OpenCode streams it, split at awkward places, becomes text, one
/// finished tool call and a finished turn.
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
  var finished: (failure: String?, Bool)?
  for event in events {
    switch event {
    case .text(let delta): text += delta
    case .tool(_, let call, true): finishedCalls.append(call)
    case .turnFinished(let failure, _): finished = (failure, true)
    default: break
    }
  }
  #expect(text == "Files: a.txt")
  #expect(finishedCalls == [ToolCall(name: "read", input: #"{"path":"."}"#, output: "a.txt", title: ".", kind: .read)])
  #expect(finished != nil && finished?.failure == nil)
}

/// OpenCode's web search question as its websearch tool asks it: one untitled
/// field whose options have ids apart from their labels and no own answer.
private let webSearchForm = try! OpenCodeSSEParser.decode(Data(#"""
{"id":"frm_1","sessionID":"ses_1","title":"Web Search","metadata":{"kind":"websearch.provider"},"fields":[
  {"key":"choice","description":"Allow OpenCode to search the web for up-to-date information?","type":"string",
   "required":true,"custom":false,"options":[
     {"value":"allow","label":"Allow search via Exa, Firecrawl, Parallel"},
     {"value":"choose","label":"Choose another provider"},
     {"value":"disable","label":"Disable web search"}]}]}
"""#.utf8))

/// OpenCode's question tool: titled fields that take the person's own answer.
private let questionToolForm = try! OpenCodeSSEParser.decode(Data(#"""
{"id":"frm_2","sessionID":"ses_1","title":"Questions","fields":[
  {"key":"q0","title":"Scope","description":"Which markets?","type":"string","custom":true,"required":true,
   "options":[{"value":"US","label":"US"},{"value":"Europe","label":"Europe"}]},
  {"key":"q1","title":"Extras","description":"Anything else?","type":"multiselect","custom":true,
   "options":[{"value":"Charts","label":"Charts"}]}]}
"""#.utf8))

@Test func openCodeQuestionIsAnsweredByOptionID() throws {
  let prompt = OpenCodeProjection.formPrompt(webSearchForm)
  #expect(prompt.kind == .question)
  #expect(prompt.text == "Web Search\nAllow OpenCode to search the web for up-to-date information?")
  #expect(prompt.options.map(\.id) == ["allow", "choose", "disable"])
  #expect(prompt.fields.first?.ownAnswer == false)

  let reply = try OpenCodeProjection.formReply(webSearchForm, answer: .option("allow"))
  #expect(reply == .object(["answer": .object(["choice": .string("allow")])]))

  // A label is not an answer, nor is text where the field takes none; an
  // untitled field is not named by its key.
  for answer: PromptAnswer in [.option("Disable web search"), .text("Use Exa")] {
    #expect(failure { try OpenCodeProjection.formReply(webSearchForm, answer: answer) } == "That is not one of the answers offered.")
  }
}

@Test func openCodeQuestionTakesOwnAnswerWhereOffered() throws {
  let prompt = OpenCodeProjection.formPrompt(questionToolForm)
  #expect(prompt.kind == .form)
  #expect(prompt.fields.map(\.ownAnswer) == [true, true])

  let reply = try OpenCodeProjection.formReply(questionToolForm, answer: .values([
    "q0": .string("Asia"), "q1": .array([.string("Charts"), .string("Tables")]),
  ]))
  #expect(reply == .object(["answer": .object([
    "q0": .string("Asia"), "q1": .array([.string("Charts"), .string("Tables")]),
  ])]))
  #expect(failure { try OpenCodeProjection.formReply(questionToolForm, answer: .values([:])) } == "Scope needs an answer.")
  #expect(failure { try OpenCodeProjection.formReply(questionToolForm, answer: .values(["q0": .string("  ")])) }
    == "That is not an answer Scope takes.")
}

@Test func openCodeFormIsRepliedToOrCancelled() throws {
  let reply = try OpenCodeProjection.formAnswer(sessionID: "ses_1", form: webSearchForm, answer: .option("disable"))
  #expect(reply.method == "POST" && reply.path == "/api/session/ses_1/form/frm_1/reply")
  #expect(reply.body == .object(["answer": .object(["choice": .string("disable")])]))

  let cancel = try OpenCodeProjection.formAnswer(sessionID: "ses_1", form: webSearchForm, answer: .declined)
  #expect(cancel.method == "DELETE" && cancel.path == "/api/session/ses_1/form/frm_1" && cancel.body == nil)
}

/// An elicitation's `enumNames` give labels apart from the values, and the
/// answer is a value.
@Test func elicitationChoiceIsCheckedByValue() throws {
  let schema = try OpenCodeSSEParser.decode(Data(#"""
  {"type":"object","required":["mode"],"properties":{"mode":{"type":"string","title":"Mode",
   "enum":["fast","careful"],"enumNames":["Go fast","Be careful"]}}}
  """#.utf8))
  let fields = try #require(PromptForms.fields(schema))
  #expect(fields.first?.options.map(\.name) == ["Go fast", "Be careful"])
  try PromptForms.check(["mode": .string("careful")], against: fields)
  #expect(failure { try PromptForms.check(["mode": .string("Be careful")], against: fields) } == "That is not an answer Mode takes.")
}

/// The message of the runtime failure `body` throws, if it throws one.
private func failure(_ body: () throws -> Any) -> String? {
  do { _ = try body() } catch RuntimeError.failed(let message) { return message } catch { return "\(error)" }
  return nil
}
