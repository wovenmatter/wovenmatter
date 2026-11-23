import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

private func update(_ json: String) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

/// Pi Durable reports a code mode script as one ACP tool call that says so in
/// `_meta`: its source in `rawInput.code`, the tool calls it made in
/// `wovenCalls`. Woven keeps it as one `.code` call holding those calls.
@Test
func anACPScriptIsOneCodeCallWithTheToolCallsItMade() throws {
  var call = ToolCall(name: "execute", input: "")
  let script = "const sessions = await tools.mcp__woven__list_sessions({});\ntext(sessions);"
  _ = ACPState.merge(try update("""
    {"sessionUpdate": "tool_call", "toolCallId": "call-1", "kind": "execute", "title": "codemode", "status": "pending",
     "rawInput": {"code": \(String(decoding: try Wire.encoder.encode(JSONValue.string(script)), as: UTF8.self))},
     "_meta": {"wovenKind": "code", "wovenCalls": []}}
    """), into: &call)
  #expect(call.kind == .code)
  #expect(call.title == "codemode")
  #expect(call.input == script)
  #expect(call.calls == [])

  // While it runs: one call done, one failed, one still running, one whose
  // arguments were cut short on the way.
  _ = ACPState.merge(try update("""
    {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress",
     "_meta": {"wovenKind": "code", "wovenCalls": [
       {"name": "mcp__woven__list_sessions", "input": {"query": "notes", "includeArchived": true}, "status": "ok"},
       {"name": "mcp__woven__read_session", "input": {"sessionID": "gone"}, "status": "error", "error": "There is no session gone."},
       {"name": "mcp__woven__set_timer", "input": {"seconds": 5}, "status": "running"},
       {"name": "mcp__woven__query_database", "input": "{\\"sql\\": \\"SELECT…", "status": "cancelled"}
     ]}}
    """), into: &call)
  #expect(call.kind == .code)
  #expect(call.input == script)
  #expect(call.calls == [
    ToolCall(name: "mcp__woven__list_sessions", input: #"{"includeArchived":true,"query":"notes"}"#, output: ""),
    ToolCall(name: "mcp__woven__read_session", input: #"{"sessionID":"gone"}"#, output: "There is no session gone.", failed: true),
    ToolCall(name: "mcp__woven__set_timer", input: #"{"seconds":5}"#),
    ToolCall(name: "mcp__woven__query_database", input: #"{"sql": "SELECT…"#, output: "Cancelled.", failed: true),
  ])

  // At its end: the script's output, and the calls from its result.
  _ = ACPState.merge(try update("""
    {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "failed",
     "content": [{"type": "content", "content": {"type": "text", "text": "Script failed"}}],
     "_meta": {"wovenKind": "code", "wovenCalls": [
       {"name": "mcp__woven__list_sessions", "input": {}, "status": "ok"},
       {"name": "mcp__woven__read_session", "input": {}, "status": "error"}
     ]}}
    """), into: &call)
  #expect(call.kind == .code)
  #expect(call.input == script)
  #expect(call.output == "Script failed")
  #expect(call.calls?.map(\.output) == ["", "Failed."])
  #expect(call.calls?.map(\.failed) == [false, true])
}

/// A script's `render_html` arrives with its page already left out; Woven
/// keeps that placeholder and shows the call as the visual reply.
@Test
func aScriptsVisualReplyKeepsThePlaceholderItArrivedWith() throws {
  var call = ToolCall(name: "execute", input: "")
  _ = ACPState.merge(try update("""
    {"sessionUpdate": "tool_call_update", "toolCallId": "call-2", "kind": "execute", "status": "completed",
     "rawInput": {"code": "await tools.mcp__woven__render_html({ html: page });"},
     "_meta": {"wovenKind": "code", "wovenCalls": [
       {"name": "mcp__woven__render_html", "input": {"html": "(48213 characters, shown in the chat)", "title": "Sales"}, "status": "ok"}
     ]}}
    """), into: &call)
  let kept = VisualReplies.withoutVisualReply(call)
  #expect(kept.kind == .code)
  let reply = try #require(kept.calls?.first)
  #expect(reply.kind == .visualReply)
  #expect(reply.input == #"{"html":"(48213 characters, shown in the chat)","title":"Sales"}"#)
}

/// A tool call that is not a script is merged as before.
@Test
func anACPToolCallWithoutCodeMetaIsUnchanged() throws {
  var call = ToolCall(name: "other", input: "")
  _ = ACPState.merge(try update("""
    {"sessionUpdate": "tool_call", "toolCallId": "call-3", "kind": "other", "title": "mcp__woven__list_sessions",
     "rawInput": {"query": "notes"}, "status": "pending"}
    """), into: &call)
  #expect(call.kind == .other)
  #expect(call.calls == nil)
  #expect(call.input == #"{"query":"notes"}"#)
}
