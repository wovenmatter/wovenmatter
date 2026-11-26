import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
import WovenLibrary
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

/// The transcript a session saves from runtime events, in the order it saves
/// them: text runs until a tool call or the message's end, and every item
/// takes its place when it finishes (`Sessions.handle`).
private func savedTranscript(_ events: [RuntimeEvent]) -> [String] {
  var saved: [String] = []
  var text = ""
  var output: [String: String] = [:]
  func flush() {
    if !text.isEmpty { saved.append("text: " + text) }
    text = ""
  }
  for event in events {
    switch event {
    case .text(let delta): text += delta
    case .messageFinished: flush()
    case .toolOutput(let id, let delta): output[id, default: ""] += delta
    case .tool(let id, let call, let finished):
      flush()
      if finished {
        let shown = (call.output ?? "").isEmpty ? output[id] ?? "" : call.output ?? ""
        saved.append(call.kind == .thinking ? "thinking: " + shown : "tool: " + call.name)
      }
    case .turnFinished: flush()
    default: break
    }
  }
  return saved
}

private func project(_ frames: [String], session: String = "") -> [RuntimeEvent] {
  var projection = OpenCodeProjection()
  projection.session = session
  return frames.flatMap { projection.receive(try! OpenCodeSSEParser.decode(Data($0.utf8))) }
}

/// OpenCode ends a step's reasoning only when the step's stream ends, after
/// its text and tool calls began (as its own history of a chat shows). The
/// reasoning still keeps its place before them, and the reply stays whole.
@Test func openCodeReasoningKeepsItsPlaceBeforeTheStepsText() {
  let events = project([
    #"{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1"}}"#,
    #"{"type":"session.reasoning.started","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0}}"#,
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"Search "}}"#,
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"first."}}"#,
    #"{"type":"session.text.started","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"Looking "}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"it up."}}"#,
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"websearch"}}"#,
    #"{"type":"session.tool.input.delta","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","delta":"{\"query\""}}"#,
    #"{"type":"session.reasoning.ended","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"text":"Search first."}}"#,
    #"{"type":"session.text.ended","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"text":"Looking it up."}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":{"query":"q"}}}"#,
    #"{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","content":[{"type":"text","text":"found"}]}}"#,
    #"{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"m1"}}"#,
    #"{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m2"}}"#,
    #"{"type":"session.reasoning.started","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0}}"#,
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"delta":"Now answer."}}"#,
    #"{"type":"session.text.started","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"delta":"Here is the answer, "}}"#,
    #"{"type":"session.reasoning.ended","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"text":"Now answer."}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"delta":"whole."}}"#,
    #"{"type":"session.text.ended","data":{"sessionID":"s","assistantMessageID":"m2","ordinal":0,"text":"Here is the answer, whole."}}"#,
    #"{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"m2"}}"#,
    #"{"type":"session.execution.succeeded","data":{"sessionID":"s"}}"#,
  ])
  #expect(savedTranscript(events) == [
    "thinking: Search first.", "text: Looking it up.", "tool: websearch",
    "thinking: Now answer.", "text: Here is the answer, whole.",
  ])
  // Reasoning streams as deltas, and the tool's input shows once complete.
  let calls = events.compactMap { if case .tool(_, let call, false) = $0 { call } else { nil } }
  #expect(calls.map(\.name) == ["thinking", "websearch", "websearch", "thinking"])
  #expect(calls.first { $0.kind == .thinking }?.title == "Thinking")
  #expect(events.filter { if case .toolOutput = $0 { true } else { false } }.count == 3)
}

/// Reasoning a step streams again after its text began shows as its own
/// item after that text, and a tool that reports its own failure failed.
@Test func openCodeResumedReasoningAndToolErrorsShow() {
  let events = project([
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"First."}}"#,
    #"{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"Partly. "}}"#,
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"delta":"Second."}}"#,
    #"{"type":"session.reasoning.ended","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"text":"First.Second."}}"#,
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"execute"}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":{"code":"x"}}}"#,
    #"{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","metadata":{"error":true},"content":[{"type":"text","text":"SyntaxError"}]}}"#,
    #"{"type":"session.execution.succeeded","data":{"sessionID":"s"}}"#,
  ])
  #expect(savedTranscript(events) == ["thinking: First.", "text: Partly. ", "thinking: Second.", "tool: execute"])
  let tool = events.compactMap { if case .tool(_, let call, true) = $0, call.name == "execute" { call } else { nil } }.first
  #expect(tool?.failed == true && tool?.kind == .code && tool?.input == "x")
}

// MARK: Code Mode

/// A Code Mode script's frames as OpenCode 2.3.2 sends them (recorded from
/// its server with a stand-in model and MCP server): its source, the tool
/// calls it made so far, whole each time, then its result.
private func scriptFrames(_ code: String, progress: [String], end: String) -> [String] {
  let source = String(decoding: try! Wire.encoder.encode(JSONValue.string(code)), as: UTF8.self)
  let text = String(decoding: try! Wire.encoder.encode(JSONValue.string(#"{"code":\#(source)}"#)), as: UTF8.self)
  return [
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"call_1","name":"execute"}}"#,
    #"{"type":"session.tool.input.ended","data":{"sessionID":"s","assistantMessageID":"m1","id":"call_1","text":\#(text)}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"call_1","input":{"code":\#(source)},"executed":false}}"#,
  ] + progress.map {
    #"{"type":"session.tool.progress","data":{"sessionID":"s","assistantMessageID":"m1","id":"call_1","metadata":{"toolCalls":\#($0)}}}"#
  } + [#"{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"m1","id":"call_1",\#(end),"executed":false}}"#]
}

private func scriptCalls(_ events: [RuntimeEvent]) -> (open: [ToolCall], finished: ToolCall?) {
  var open: [ToolCall] = []
  var finished: ToolCall?
  for case .tool("call_1", let call, let done) in events {
    if done { finished = call } else { open.append(call) }
  }
  return (open, finished)
}

/// A script is one `.code` call: its source, its output, and the tool calls
/// it made as each one runs and ends. A progress report that changes nothing
/// sends nothing.
@Test func openCodeScriptIsOneCodeCallWithTheToolsItCalled() throws {
  let code = "const a = await tools.woven.slow({});\nconst b = await tools.woven.echo({text: \"after\"});\nconst c = await tools.woven.slow({});\nreturn [a, b, c];\n"
  let done = #"[{"tool":"woven.slow","status":"completed"},{"tool":"woven.echo","status":"completed","input":{"text":"after"}},{"tool":"woven.slow","status":"completed"}]"#
  let events = project(scriptFrames(code, progress: [
    #"[{"tool":"woven.slow","status":"running"}]"#,
    #"[{"tool":"woven.slow","status":"running"}]"#,
    #"[{"tool":"woven.slow","status":"completed"}]"#,
    #"[{"tool":"woven.slow","status":"completed"},{"tool":"woven.echo","status":"completed","input":{"text":"after"}},{"tool":"woven.slow","status":"running"}]"#,
    done,
  ], end: #""content":[{"type":"text","text":"[\"slept\",\"echo:after\",\"slept\"]"}],"metadata":{"toolCalls":\#(done),"truncated":false}"#))

  let (open, finished) = scriptCalls(events)
  // Started, its input whole, called, then four changes of its calls.
  #expect(open.count == 7)
  #expect(open.allSatisfy { $0.kind == .code })
  #expect(open[2].input == code && open[3].calls == [ToolCall(name: "woven.slow", input: "{}")])
  #expect(open[4].calls?.first?.output == "")
  let call = try #require(finished)
  #expect(call.kind == .code && call.input == code && !call.failed && call.title == nil)
  #expect(call.output == #"["slept","echo:after","slept"]"#)
  #expect(call.calls == [ToolCall(name: "woven.slow", input: "{}", output: ""),
                         ToolCall(name: "woven.echo", input: #"{"text":"after"}"#, output: ""),
                         ToolCall(name: "woven.slow", input: "{}", output: "")])
}

/// A script that fails is a failed call, also when OpenCode reports it as a
/// success with `metadata.error`; a tool call it made that failed says so,
/// and one still out when the turn is stopped ended with it.
@Test func openCodeScriptFailuresShow() throws {
  let thrown = project(scriptFrames("await tools.woven.echo({text: \"first\"});\nawait tools.woven.fail({});\n", progress: [
    #"[{"tool":"woven.echo","status":"running","input":{"text":"first"}}]"#,
  ], end: #""content":[{"type":"text","text":"boom from tool"}],"metadata":{"toolCalls":[{"tool":"woven.echo","status":"completed","input":{"text":"first"}},{"tool":"woven.fail","status":"error"}],"error":true,"truncated":false}"#))
  let failed = try #require(scriptCalls(thrown).finished)
  #expect(failed.failed && failed.output == "boom from tool")
  #expect(failed.calls == [ToolCall(name: "woven.echo", input: #"{"text":"first"}"#, output: ""),
                           ToolCall(name: "woven.fail", input: "{}", output: OpenCodeProjection.refusedByOpenCode, failed: true)])

  // Woven answered that call, so the call says Woven's error; a turn's end forgets what was not shown.
  let native = "ses_\(UUID().uuidString)"
  OpenCodeToolFailures.shared.record(session: native, tool: "fail", input: .object([:]), message: "No artifact missing.")
  OpenCodeToolFailures.shared.record(session: native, tool: "other", input: .object([:]), message: "Unclaimed.")
  let answered = project(scriptFrames("await tools.woven.fail({});\n", progress: [#"[{"tool":"woven.fail","status":"error"}]"#],
    end: #""content":[{"type":"text","text":"No artifact missing."}],"metadata":{"toolCalls":[{"tool":"woven.fail","status":"error"}],"error":true,"truncated":false}"#)
    + [#"{"type":"session.execution.succeeded","data":{"sessionID":"s"}}"#], session: native)
  #expect(try #require(scriptCalls(answered).finished).calls == [ToolCall(name: "woven.fail", input: "{}", output: "No artifact missing.", failed: true)])
  #expect(OpenCodeToolFailures.shared.claim(session: native, tool: "other", input: nil) == nil)

  let syntax = project(scriptFrames("await tools.woven.render_html({ html: `<p>unterminated\n", progress: [],
    end: #""content":[{"type":"text","text":"SyntaxError: Unterminated template. Code must be plain JavaScript written as a program body. (line 1, col 40)"}],"metadata":{"toolCalls":[],"error":true,"truncated":false}"#))
  let broken = try #require(scriptCalls(syntax).finished)
  #expect(broken.failed && broken.calls == [] && broken.output?.hasPrefix("SyntaxError") == true)

  var frames = scriptFrames("await tools.woven.slow({});", progress: [#"[{"tool":"woven.slow","status":"running"}]"#], end: "")
  frames[frames.count - 1] = #"{"type":"session.execution.interrupted","data":{"sessionID":"s","reason":"user"}}"#
  let stopped = try #require(scriptCalls(project(frames)).finished)
  #expect(stopped.failed && stopped.calls?.first?.failed == true && stopped.calls?.first?.output != nil)
}

/// Images a script's tool calls returned reach the model as file parts of
/// the result; the call keeps only their type, never their data.
@Test func openCodeScriptImagesStayOutOfItsOutput() throws {
  let events = project(scriptFrames("const image = await tools.woven.preview_html({ path: \"/tmp/a.html\" });\nreturn image;", progress: [],
    end: #""content":[{"type":"text","text":"{\"contentHeight\":120}"},{"type":"file","uri":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==","mime":"image/png"}],"metadata":{"toolCalls":[{"tool":"woven.preview_html","status":"completed","input":{"path":"/tmp/a.html"}}],"truncated":false}"#))
  let call = try #require(scriptCalls(events).finished)
  #expect(call.output == "{\"contentHeight\":120}\n[image/png]")
  #expect(call.calls?.first?.input == #"{"path":"/tmp/a.html"}"#)
}

/// A tool a script calls asks for permission as itself, for the script's
/// call; the prompt is answered like any other.
@Test func openCodeScriptsToolAsksAsItself() throws {
  let asked = try OpenCodeSSEParser.decode(Data(#"""
    {"id":"per_1","sessionID":"ses_1","action":"woven_render_html","resources":["*"],"save":["*"],
     "metadata":{"input":{"title":"Sales"}},"source":{"type":"tool","messageID":"msg_1","id":"call_1"}}
    """#.utf8))
  let prompt = OpenCodeProjection.permissionPrompt(asked)
  #expect(prompt.id == "per_1" && prompt.kind == .approval && prompt.text == "woven_render_html")
  #expect(OpenCodeProjection.permissionReply(.option("once")) == .object(["decision": .string("once")]))
}

/// Reasoning without text shows nothing, and a turn that ends mid-reasoning
/// keeps what was streamed.
@Test func openCodeReasoningWithoutTextIsNotShown() {
  let events = project([
    #"{"type":"session.reasoning.started","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0}}"#,
    #"{"type":"session.reasoning.ended","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":0,"text":""}}"#,
    #"{"type":"session.reasoning.started","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":2}}"#,
    #"{"type":"session.reasoning.delta","data":{"sessionID":"s","assistantMessageID":"m1","ordinal":2,"delta":"Half"}}"#,
    #"{"type":"session.execution.interrupted","data":{"sessionID":"s","reason":"user"}}"#,
  ])
  #expect(savedTranscript(events) == ["thinking: Half"])
}

/// A running command's output, reported whole as it grows, streams as what
/// is new.
@Test func openCodeToolProgressStreamsWhatIsNew() {
  let events = project([
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"bash"}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":{"command":"ls"}}}"#,
    #"{"type":"session.tool.progress","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","metadata":{"output":"a\n"}}}"#,
    #"{"type":"session.tool.progress","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","metadata":{"output":"a\nb\n"}}}"#,
  ])
  let deltas = events.compactMap { if case .toolOutput(_, let delta) = $0 { delta } else { nil } }
  #expect(deltas == ["a\n", "b\n"])
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

// MARK: Woven's tools from OpenCode's scripts

/// MCP over the tool socket as OpenCode's bridge speaks it: the key, then
/// one request at a time, each naming the native session in `_meta`.
private final class ToolSocket: @unchecked Sendable {
  private let fd: Int32
  private var buffer = Data()
  private var nextID = 0

  init(_ access: ToolAccess) throws {
    #if canImport(Glibc)
    fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array((access.arguments.last ?? "").utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw ToolFailure("The tool socket is not there.") }
    send(.object(["key": .string(access.environment["WOVEN_MCP_KEY"] ?? "")]))
  }

  deinit { close(fd) }

  /// The result of one request, read on a thread of its own.
  func request(_ method: String, _ params: JSONValue) async -> JSONValue? {
    nextID += 1
    let id = nextID
    send(.object(["jsonrpc": .string("2.0"), "id": .integer(Int64(id)), "method": .string(method), "params": params]))
    return await withCheckedContinuation { continuation in
      Thread.detachNewThread { continuation.resume(returning: self.line()?["result"]) }
    }
  }

  func call(_ name: String, _ arguments: JSONValue, session: String) async -> (text: String, failed: Bool) {
    let result = await result(name, arguments, session: session)
    let text = (result?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    return (result == nil ? "No answer." : text, result?["isError"]?.bool ?? true)
  }

  /// The whole result of one call.
  func result(_ name: String, _ arguments: JSONValue, session: String) async -> JSONValue? {
    await request("tools/call", .object([
      "name": .string(name), "arguments": arguments, "_meta": .object(["ai.opencode/sessionID": .string(session)]),
    ]))
  }

  private func send(_ value: JSONValue) {
    let bytes = Array((try! Wire.encoder.encode(value)) + [10])
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  }

  private func line() -> JSONValue? {
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !buffer.contains(10) {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 { return nil }
      buffer.append(contentsOf: chunk[0..<count])
    }
    let end = buffer.firstIndex(of: 10)!
    defer { buffer.removeSubrange(buffer.startIndex...end) }
    return try? Wire.decoder.decode(JSONValue.self, from: Data(buffer[buffer.startIndex..<end]))
  }
}

/// OpenCode as Woven's server meets it, without a model: one process for
/// every session, which reaches the Woven MCP through one bridge. Each turn
/// replays a script's recorded frames through the OpenCode projection and,
/// where the script called a Woven tool, calls it over that bridge naming
/// its native session, as OpenCode's Code Mode does.
private final class RecordedOpenCode: Runtime {
  /// The frames before the script's tool call, the call, and the frames after.
  let script: (before: [String], tool: String, arguments: JSONValue, after: [String])?

  init(script: (before: [String], tool: String, arguments: JSONValue, after: [String])? = nil) { self.script = script }

  var kind: RuntimeKind { .openCode }
  var sharesToolBridge: Bool { true }

  func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    RecordedOpenCodeSession(handle: start.nativeHandle ?? "ses_" + UUID().uuidString.lowercased(), tools: start.tools,
                            script: script)
  }
}

private final class RecordedOpenCodeSession: RuntimeSession {
  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let tools: ToolAccess?
  private let script: (before: [String], tool: String, arguments: JSONValue, after: [String])?

  init(handle: String, tools: ToolAccess?, script: (before: [String], tool: String, arguments: JSONValue, after: [String])?) {
    nativeHandle = handle
    self.tools = tools
    self.script = script
    (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
  }

  var configuration: SessionConfiguration { SessionConfiguration() }

  func send(_ turn: Turn) async throws {
    guard let script, let tools else { throw RuntimeError.failed("Nothing recorded.") }
    let emit = emit, handle = nativeHandle
    Task {
      var projection = OpenCodeProjection()
      func replay(_ frames: [String]) {
        for frame in frames {
          for event in projection.receive(try! OpenCodeSSEParser.decode(Data(frame.utf8))) { emit.yield(event) }
        }
      }
      replay(script.before)
      if let socket = try? ToolSocket(tools) { _ = await socket.call(script.tool, script.arguments, session: handle) }
      replay(script.after)
    }
  }

  func steer(_ turn: Turn) async throws -> Bool { false }
  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration { configuration }
  func answer(promptID: String, with answer: PromptAnswer) async throws {}
  func interrupt() async throws {}
  func stop() async {
    emit.yield(.exited)
    emit.finish()
  }
}

private func startServer(_ openCode: RecordedOpenCode) async throws -> (server: WovenServer, ui: Client) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(
    dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test", machineName: "Studio",
    tailnet: StandInTailnet(), runtimes: [StandInRuntime(), openCode], discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  let ui = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
  return (server, ui)
}

/// A script in OpenCode that publishes a visual reply: the visual reply is
/// saved in its place, then the script as one call holding the tool call,
/// and no copy of the page is shown or saved anywhere else.
@Test(.timeLimit(.minutes(1)))
func anOpenCodeScriptThatPublishesAVisualReplyIsSavedAsTheVisualReplyAndOneScript() async throws {
  let html = "<!doctype html><title>Sales</title><h1>Quarterly sales</h1>" + String(repeating: "<i>bar</i>", count: 400)
  let code = "const shown = await tools.woven.render_html({ title: \"Sales\", html: `\(html)` });\nreturn shown;\n"
  let input = String(decoding: try Wire.encoder.encode(JSONValue.object(["title": .string("Sales"), "html": .string(html)])),
                     as: UTF8.self)
  let frames = scriptFrames(code, progress: [#"[{"tool":"woven.render_html","status":"running","input":\#(input)}]"#],
    end: #""content":[{"type":"text","text":"Shown in the chat: “Sales”."}],"metadata":{"toolCalls":[{"tool":"woven.render_html","status":"completed","input":\#(input)}],"truncated":false}"#)
    + [#"{"type":"session.execution.succeeded","data":{"sessionID":"s"}}"#]
  let openCode = RecordedOpenCode(script: (before: Array(frames.prefix(4)), tool: "render_html",
                                           arguments: .object(["title": .string("Sales"), "html": .string(html)]),
                                           after: Array(frames.dropFirst(4))))
  let (server, ui) = try await startServer(openCode)
  defer { server.stopLater() }
  let session = try await ui.call(CreateSession(runtime: .openCode, title: "Sales"))
  _ = try await ui.call(UpdateSession(sessionID: session.id, tools: []))

  let subscription = try await ui.subscribe(SubscribeSession(sessionID: session.id))
  _ = try await ui.call(SendTurn(sessionID: session.id, text: "Chart the sales."))
  var shown: [String] = []
  for try await event in subscription.events {
    shown.append(String(decoding: try Wire.encoder.encode(event), as: UTF8.self))
    if event == .runState(.idle) { break }
  }

  let items = try await ui.call(SessionItems(sessionID: session.id))
  guard items.count == 4, case .visualReply(let reply) = items[1].content, case .toolCall(let call) = items[2].content else {
    Issue.record("Expected the message, the visual reply, the script, then the turn's end: \(items.map(\.content))")
    return
  }
  #expect(reply.digest == Library.digest(of: Data(html.utf8)) && reply.title == "Sales")
  #expect(call.kind == .code && !call.failed && call.output == "Shown in the chat: “Sales”.")
  #expect(call.calls?.map(\.kind) == [.visualReply] && call.calls?.first?.output == "")
  for text in shown + [String(decoding: try Wire.encoder.encode(items), as: UTF8.self)] {
    #expect(!text.contains("Quarterly sales"))
  }
}

/// Every Woven tool answers a script in OpenCode, which names its native
/// session in each call over the one bridge the whole process shares: the
/// call is the session's own. Each is listed under a name a script can
/// write and with arguments OpenCode's catalog renders, and Woven's
/// instructions to OpenCode give each one's exact call.
@Test(.timeLimit(.minutes(2)))
func everyWovenToolAnswersAnOpenCodeScriptAsItsSession() async throws {
  let (server, ui) = try await startServer(RecordedOpenCode())
  defer { server.stopLater() }
  let session = try await ui.call(CreateSession(runtime: .openCode, title: "Planner"))
  _ = try await ui.call(UpdateSession(sessionID: session.id, tools: Set(ToolGroup.allCases)))
  try await server.library.setNativeSession(session.id, runtime: .openCode, handle: "ses_planner")
  let builder = try await ui.call(CreateSession(runtime: StandInRuntime.kind, title: "Builder"))
  let page = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(UUID().uuidString).html")
  let html = "<!doctype html><title>Plan</title><p>From a file</p>"
  try Data(html.utf8).write(to: page)
  defer { try? FileManager.default.removeItem(at: page) }

  let access = try #require(server.toolKeysForTests.access(.runtime(.openCode)))
  let socket = try ToolSocket(access)
  let listed = await socket.request("tools/list", .object([:]))?["tools"]?.array ?? []
  let catalog = wovenToolCatalog()
  #expect(listed.compactMap { $0["name"]?.string } == catalog.map(\.name))
  for tool in catalog {
    #expect(tool.name.wholeMatch(of: /[A-Za-z_$][A-Za-z0-9_$]*/) != nil, "\(tool.name)")
    let call = try #require(WovenInstructions.signature(tool, namespace: "woven"), "\(tool.name)")
    #expect(access.instructions.contains("- " + call + " → " + WovenInstructions.returns(tool) + " // "), "\(tool.name)")
  }

  let when = "2030-01-01T09:00:00Z"
  // Minimal arguments for each tool, and whether it succeeds with them.
  let calls: [(String, JSONValue, Bool)] = [
    ("list_sessions", .object([:]), true),
    ("read_session", .object(["sessionID": .string(session.id)]), true),
    ("start_session", .object(["runtime": .string(StandInRuntime.kind.rawValue), "title": .string("Helper"), "message": .string("Hello")]), true),
    ("send_to_session", .object(["sessionID": .string(builder.id), "text": .string("Hi")]), true),
    ("stop_session", .object(["sessionID": .string(builder.id)]), true),
    ("render_html", .object(["path": .string(page.path)]), true),
    ("list_artifacts", .object([:]), true),
    ("read_artifact", .object(["artifactID": .string("missing")]), false),
    ("create_artifact", .object(["kind": .string("note"), "title": .string("Plan"), "text": .string("# Plan")]), true),
    ("edit_artifact", .object(["artifactID": .string("missing"), "basedOn": .string("x"), "title": .string("Plan")]), false),
    ("describe_database", .object([:]), true),
    ("query_database", .object(["databaseID": .string("missing"), "sql": .string("SELECT 1")]), false),
    ("execute_database", .object(["databaseID": .string("missing"), "sql": .string("CREATE TABLE t (a)")]), false),
    ("create_database", .object(["name": .string("Scores")]), true),
    ("list_places", .object([:]), true),
    ("search_library", .object([:]), true),
    ("list_bots", .object([:]), true),
    ("message_bot", .object(["botID": .string("missing"), "text": .string("Hi")]), false),
    ("browser", .object(["action": .string("tabs")]), false),
    ("computer", .object(["action": .string("status")]), false),
    ("preview_html", .object(["path": .string(page.path)]), false),
    ("list_schedules", .object([:]), true),
    ("create_scheduled_task", .object(["title": .string("Daily"), "prompt": .string("Check"), "startsAt": .string(when),
                                       "runtime": .string(StandInRuntime.kind.rawValue)]), true),
    ("change_scheduled_task", .object(["scheduleID": .string("missing")]), false),
    ("delete_schedule", .object(["scheduleID": .string("missing")]), false),
    ("set_timer", .object(["afterSeconds": .integer(3600), "instruction": .string("Check")]), true),
    ("set_wake_up", .object(["at": .string(when), "message": .string("Check")]), true),
    ("goal_met", .object(["evidence": .string("Done")]), false),
  ]
  #expect(calls.map(\.0) == catalog.map(\.name))
  for (name, arguments, succeeds) in calls {
    let result = await socket.call(name, arguments, session: "ses_planner")
    #expect(!result.text.contains("not one Woven Matter runs") && !result.text.contains("has no tool"), "\(name): \(result.text)")
    #expect(result.failed == !succeeds, "\(name): \(result.text)")
    if name == "list_sessions" {
      let planner = try? JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))["sessions"]?.array?
        .first { $0["id"]?.string == session.id }
      #expect(planner?["you"] == .bool(true) && planner?["title"]?.string == "Planner", "\(result.text)")
    }
    // A failure is kept for the session's projection to show in the script's card.
    if !succeeds { #expect(OpenCodeToolFailures.shared.claim(session: "ses_planner", tool: name, input: arguments) == result.text, "\(name)") }
  }
  // The page from the file is this session's visual reply.
  let items = try await ui.call(SessionItems(sessionID: session.id))
  let reply = items.compactMap { if case .visualReply(let reply) = $0.content { reply } else { nil } }.first
  #expect(reply?.digest == Library.digest(of: Data(html.utf8)) && reply?.title == "Plan")
  // A native session Woven Matter does not run is refused.
  #expect(await socket.call("list_sessions", .object([:]), session: "ses_other").text.contains("not one Woven Matter runs"))
}

/// Every Woven tool's success is its value: `structuredContent` that its
/// declared output schema accepts, and the same JSON, compact, as its text,
/// with any image after it. A failure is its text alone. The calls hand
/// each other the ids they return, as a script does.
@Test(.timeLimit(.minutes(2)))
func everyWovenToolAnswersWithAValueItsOutputSchemaDescribes() async throws {
  let (server, ui) = try await startServer(RecordedOpenCode())
  defer { server.stopLater() }
  let session = try await ui.call(CreateSession(runtime: .openCode, title: "Planner"))
  _ = try await ui.call(UpdateSession(sessionID: session.id, tools: Set(ToolGroup.allCases)))
  try await server.library.setNativeSession(session.id, runtime: .openCode, handle: "ses_planner")
  _ = try await server.library.updateSession(session.id, goal: .some("Plan the week"))
  let builder = try await ui.call(CreateSession(runtime: StandInRuntime.kind, title: "Builder"))
  let page = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(UUID().uuidString).html")
  try Data("<!doctype html><title>Plan</title><p>From a file</p>".utf8).write(to: page)
  defer { try? FileManager.default.removeItem(at: page) }

  // This Mac's UI, answering as the app does: JSON text, and an image for a preview.
  let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  let asked = try await ui.subscribe(SubscribeUITools())
  let answering = Task {
    for try await call in asked.events {
      let content: [ToolContent] = switch (call.tool, call.arguments["action"]?.string) {
      case ("browser", _): [.text(#"[{"tabId":"t1","url":"https://example.com","title":"Example","loading":false}]"#)]
      case ("computer", _): [.text(#"{"engine":"cua","screenRecording":true,"accessibility":true}"#)]
      default: [.text(#"{"width":728,"contentHeight":120,"capturedHeight":120}"#), .image(data: png, mimeType: "image/png")]
      }
      _ = try await ui.call(AnswerUITool(id: call.id, result: ToolResult(content: content)))
    }
  }
  defer { answering.cancel() }

  let access = try #require(server.toolKeysForTests.access(.runtime(.openCode)))
  let socket = try ToolSocket(access)
  let listed = await socket.request("tools/list", .object([:]))?["tools"]?.array ?? []
  let catalog = wovenToolCatalog()
  for tool in catalog {
    let entry = listed.first { $0["name"]?.string == tool.name }
    #expect(entry?["outputSchema"] == tool.output && tool.output["type"]?.string == "object", "\(tool.name)")
    #expect(entry?["_meta"]?["wovenImages"]?.bool == (tool.images ? true : nil), "\(tool.name)")
  }

  var values: [String: JSONValue] = [:]
  func value(_ name: String, _ key: String) -> JSONValue { values[name]?[key] ?? .null }
  let when = "2030-01-01T09:00:00Z"
  // Each call's arguments, from the values before it.
  let calls: [(String, () -> JSONValue)] = [
    ("list_sessions", { .object([:]) }),
    ("start_session", { .object(["runtime": .string(StandInRuntime.kind.rawValue), "title": .string("Helper"), "message": .string("Hello")]) }),
    ("send_to_session", { .object(["sessionID": .string(builder.id), "text": .string("Hi")]) }),
    ("stop_session", { .object(["sessionID": .string(builder.id)]) }),
    ("read_session", { .object(["sessionID": .string(builder.id)]) }),
    ("render_html", { .object(["path": .string(page.path)]) }),
    ("create_artifact", { .object(["kind": .string("note"), "title": .string("Plan"), "text": .string("# Plan")]) }),
    ("list_artifacts", { .object([:]) }),
    ("read_artifact", { .object(["artifactID": value("create_artifact", "artifactID")]) }),
    ("edit_artifact", { .object(["artifactID": value("read_artifact", "id"), "basedOn": value("read_artifact", "basedOn"),
                                 "title": .string("Week")]) }),
    ("create_database", { .object(["name": .string("Scores")]) }),
    ("execute_database", { .object(["databaseID": value("create_database", "databaseID"),
                                    "sql": .string("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)")]) }),
    ("describe_database", { .object(["databaseID": value("create_database", "databaseID")]) }),
    ("query_database", { .object(["databaseID": value("create_database", "databaseID"), "sql": .string("SELECT a FROM t")]) }),
    ("list_places", { .object([:]) }),
    ("search_library", { .object([:]) }),
    ("list_bots", { .object([:]) }),
    ("message_bot", { .object(["botID": .string("missing"), "text": .string("Hi")]) }),
    ("browser", { .object(["action": .string("tabs")]) }),
    ("computer", { .object(["action": .string("status")]) }),
    ("preview_html", { .object(["path": .string(page.path)]) }),
    ("create_scheduled_task", { .object(["title": .string("Daily"), "prompt": .string("Check"), "startsAt": .string(when),
                                         "runtime": .string(StandInRuntime.kind.rawValue)]) }),
    ("change_scheduled_task", { .object(["scheduleID": value("create_scheduled_task", "scheduleID"), "title": .string("Weekly")]) }),
    ("list_schedules", { .object([:]) }),
    ("delete_schedule", { .object(["scheduleID": value("create_scheduled_task", "scheduleID")]) }),
    ("set_timer", { .object(["afterSeconds": .integer(3600), "instruction": .string("Check")]) }),
    ("set_wake_up", { .object(["at": .string(when), "message": .string("Check")]) }),
    ("goal_met", { .object(["evidence": .string("Done")]) }),
  ]
  #expect(Set(calls.map(\.0)) == Set(catalog.map(\.name)))
  for (name, arguments) in calls {
    let tool = try #require(catalog.first { $0.name == name })
    let result = try #require(await socket.result(name, arguments(), session: "ses_planner"), "\(name)")
    let content = result["content"]?.array ?? []
    let text = content.first?["text"]?.string ?? ""
    // Bots run on no machine here.
    if name == "message_bot" {
      #expect(result["isError"]?.bool == true && result["structuredContent"] == nil && content.count == 1, "\(name): \(text)")
      continue
    }
    #expect(result["isError"]?.bool == false, "\(name): \(text)")
    let structured = try #require(result["structuredContent"], "\(name): \(text)")
    values[name] = structured
    #expect(structured.objectValue != nil, "\(name)")
    #expect(schemaProblems(structured, tool.output).isEmpty, "\(name): \(schemaProblems(structured, tool.output)) in \(text)")
    #expect(text == String(decoding: try Wire.encoder.encode(structured), as: UTF8.self), "\(name): \(text)")
    let images = content.dropFirst()
    #expect(images.allSatisfy { $0["type"]?.string == "image" } && images.isEmpty == !(name == "preview_html"), "\(name)")
    #expect(!text.contains(png), "\(name)")
  }
  // Values a script reads.
  #expect(value("list_sessions", "sessions").array?.contains { $0["id"]?.string == session.id && $0["you"] == .bool(true) } == true)
  #expect(value("read_session", "id").string == builder.id && value("read_session", "text").string?.isEmpty == false)
  #expect(value("start_session", "sessionID").string?.isEmpty == false)
  #expect(value("read_artifact", "text").string?.contains("Plan") == true)
  #expect(value("edit_artifact", "basedOn").string != value("read_artifact", "basedOn").string)
  #expect(value("execute_database", "changes").int == 1)
  #expect(value("query_database", "rows") == .array([.object(["a": .string("1")])]))
  #expect(value("describe_database", "tables").array?.first?["rowCount"]?.int == 1)
  #expect(value("browser", "tabs").array?.first?["tabId"]?.string == "t1")
  #expect(value("computer", "engine").string == "cua")
  #expect(value("preview_html", "contentHeight").int == 120 && value("preview_html", "missingImages") == .array([]))
  #expect(value("list_schedules", "schedules").array?.contains { $0["title"]?.string == "Weekly" } == true)
  #expect(value("goal_met", "cleared") == .bool(true))
  // A failure is its text alone.
  let failed = try #require(await socket.result("read_artifact", .object(["artifactID": .string("missing")]), session: "ses_planner"))
  #expect(failed["isError"]?.bool == true && failed["structuredContent"] == nil)
}

/// What is wrong with `value` by `schema`, as far as the type, properties,
/// required and items keywords go.
private func schemaProblems(_ value: JSONValue, _ schema: JSONValue, at path: String = "$") -> [String] {
  var problems: [String] = []
  if let type = schema["type"]?.string {
    let fits = switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("integer", .integer): true
    case ("number", .integer), ("number", .double): true
    case ("null", .null): true
    default: false
    }
    if !fits { return ["\(path) is not a \(type)"] }
  }
  if case .object(let fields) = value {
    for name in (schema["required"]?.array ?? []).compactMap(\.string) where fields[name] == nil {
      problems.append("\(path).\(name) is missing")
    }
    if case .object(let properties)? = schema["properties"] {
      for (name, field) in fields {
        if let property = properties[name] { problems += schemaProblems(field, property, at: "\(path).\(name)") }
      }
    }
  }
  if case .array(let items) = value, let item = schema["items"] {
    for (index, element) in items.enumerated() { problems += schemaProblems(element, item, at: "\(path)[\(index)]") }
  }
  return problems
}

/// OpenCode's question tool is a `.question` call holding each question with
/// what the person answered, in the order asked; a dismissed one is failed
/// and keeps its questions unanswered.
@Test func openCodeQuestionToolCarriesItsQuestionsAndAnswers() throws {
  let input = #"{"questions":[{"header":"Favourite colour","question":"Which colour?","options":[{"label":"Red","description":"r"},{"label":"Green","description":"g"}]},{"header":"Fruits","question":"Which fruits?","multiple":true,"options":[{"label":"Pear","description":"p"},{"label":"Plum","description":"q"}]},{"header":"Nickname","question":"Your nickname?","options":[]}]}"#
  func asked(_ end: String) -> ToolCall? {
    project([
      #"{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1"}}"#,
      #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"question"}}"#,
      #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":\#(input)}}"#,
      end,
    ]).compactMap { event -> ToolCall? in
      if case .tool(_, let call, true) = event { return call }
      return nil
    }.last
  }
  let answered = try #require(asked(#"{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","content":[{"type":"text","text":"User has answered your questions"}],"metadata":{"answers":[["Green"],["Pear","Plum"],[]]}}}"#))
  #expect(answered.kind == .question && !answered.failed)
  #expect(answered.questions == [
    ToolQuestion(title: "Favourite colour", text: "Which colour?", options: ["Red", "Green"], answer: ["Green"]),
    ToolQuestion(title: "Fruits", text: "Which fruits?", options: ["Pear", "Plum"], answer: ["Pear", "Plum"]),
    ToolQuestion(title: "Nickname", text: "Your nickname?", answer: []),
  ])

  let dismissal = #"{"type":"session.tool.failed","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","error":{"message":"The user dismissed this question"}}}"#
  let dismissed = try #require(asked(dismissal))
  #expect(!dismissed.failed && dismissed.output == "The user dismissed this question")
  #expect(dismissed.questions?.count == 3 && dismissed.questions?.allSatisfy { $0.answer == nil } == true)

  // A question OpenCode failed for another reason is failed, with its error.
  let refused = try #require(asked(#"{"type":"session.tool.failed","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","error":{"message":"Invalid input"}}}"#))
  #expect(refused.failed && refused.output == "Invalid input")

  // After a dismissal OpenCode ends the turn as interrupted by "shutdown",
  // which is no failure; "shutdown" with no dismissal is its server stopping.
  func ending(_ frames: [String]) -> String?? {
    project(frames + [#"{"type":"session.execution.interrupted","data":{"sessionID":"s","reason":"shutdown"}}"#])
      .compactMap { if case .turnFinished(let failure, _) = $0 { failure } else { nil } }.first
  }
  let start = [
    #"{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1"}}"#,
    #"{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","name":"question"}}"#,
    #"{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"m1","id":"c1","input":\#(input)}}"#,
  ]
  #expect(ending(start + [dismissal]) == .some(nil))
  #expect(ending(Array(start.prefix(1))) == .some("OpenCode stopped the turn."))

  // A question still open when the person stops the turn ends unanswered, not failed.
  let stopped = project(start + [#"{"type":"session.execution.interrupted","data":{"sessionID":"s","reason":"user"}}"#])
    .compactMap { event -> ToolCall? in if case .tool(_, let call, true) = event { call } else { nil } }.last
  #expect(stopped?.kind == .question && stopped?.failed == false)
}
