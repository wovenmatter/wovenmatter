import Foundation

// A scripted ACP agent for tests. It keeps each native session as a file in
// $FAKE_ACP_STORE, so a session outlives the process the way a real
// runtime's does, and deleting the file loses it. Each turn answers
// "pid <process> turn <n>: <text>" and makes one tool call; a turn whose text
// contains "permission" first asks for permission and says which option was
// chosen; one containing "question" asks a one-field form and says the answer.

let store = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FAKE_ACP_STORE"] ?? NSTemporaryDirectory())
let pid = ProcessInfo.processInfo.processIdentifier
var nextRequest = 1000
var waiting: [Int: @MainActor ([String: Any]) -> Void] = [:]
var turns: [String: Int] = [:]

func send(_ message: [String: Any]) {
  var object = message
  object["jsonrpc"] = "2.0"
  guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func update(_ session: String, _ update: [String: Any]) {
  send(["method": "session/update", "params": ["sessionId": session, "update": update]])
}

let configOptions: [[String: Any]] = [
  ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "fake-small",
   "options": [["value": "fake-small", "name": "Fake small"], ["value": "fake-large", "name": "Fake large"]]],
]

func file(_ session: String) -> URL { store.appendingPathComponent(session) }

@MainActor func prompt(_ id: Any, _ session: String, _ text: String) {
  let number = (turns[session] ?? (Int((try? String(contentsOf: file(session), encoding: .utf8)) ?? "") ?? 0)) + 1
  turns[session] = number
  try? String(number).write(to: file(session), atomically: true, encoding: .utf8)
  func finish(_ chosen: String?) {
    update(session, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "pid \(pid) turn \(number): "]])
    update(session, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text + (chosen.map { " (\($0))" } ?? "")]])
    update(session, ["sessionUpdate": "tool_call", "toolCallId": "call-\(number)", "title": "List files", "kind": "execute",
                     "status": "in_progress", "rawInput": ["command": "ls"]])
    update(session, ["sessionUpdate": "tool_call_update", "toolCallId": "call-\(number)", "status": "completed",
                     "content": [["type": "content", "content": ["type": "text", "text": "a.txt"]]]])
    send(["id": id, "result": ["stopReason": "end_turn", "usage": ["inputTokens": 3, "outputTokens": 2]]])
  }
  if text.contains("question") {
    nextRequest += 1
    waiting[nextRequest] = { result in
      let content = result["content"] as? [String: Any]
      finish(result["action"] as? String == "accept" ? content?["colour"] as? String : result["action"] as? String)
    }
    send(["id": nextRequest, "method": "elicitation/create", "params": [
      "sessionId": session, "mode": "form", "message": "Which colour?",
      "requestedSchema": ["type": "object", "required": ["colour"],
                          "properties": ["colour": ["type": "string", "enum": ["red", "blue"]]]],
    ]])
    return
  }
  guard text.contains("permission") else { return finish(nil) }
  nextRequest += 1
  waiting[nextRequest] = { result in
    let outcome = result["outcome"] as? [String: Any]
    finish(outcome?["optionId"] as? String ?? "cancelled")
  }
  send(["id": nextRequest, "method": "session/request_permission", "params": [
    "sessionId": session, "toolCall": ["toolCallId": "call-\(number)", "title": "Run ls"],
    "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"], ["optionId": "deny", "name": "Deny", "kind": "reject_once"]],
  ]])
}

while let line = readLine() {
  guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
  let params = message["params"] as? [String: Any] ?? [:]
  guard let method = message["method"] as? String else {
    if let id = message["id"] as? Int, let reply = waiting.removeValue(forKey: id) { reply(message["result"] as? [String: Any] ?? [:]) }
    continue
  }
  let id = message["id"]
  switch method {
  case "initialize":
    send(["id": id!, "result": ["protocolVersion": 1, "agentCapabilities": ["loadSession": true]]])
  case "session/new":
    let session = UUID().uuidString.lowercased()
    try? "0".write(to: file(session), atomically: true, encoding: .utf8)
    send(["id": id!, "result": ["sessionId": session, "configOptions": configOptions]])
  case "session/load":
    let session = params["sessionId"] as? String ?? ""
    guard FileManager.default.fileExists(atPath: file(session).path) else {
      send(["id": id!, "error": ["code": -32002, "message": "Resource not found"]])
      continue
    }
    // A resumed session replays its history first.
    update(session, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "replayed history"]])
    send(["id": id!, "result": ["configOptions": configOptions]])
  case "session/prompt":
    let session = params["sessionId"] as? String ?? ""
    let text = (params["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
    prompt(id!, session, text)
  case "session/set_config_option":
    var options = configOptions
    options[0]["currentValue"] = params["value"]
    send(["id": id!, "result": ["configOptions": options]])
  case "session/cancel":
    break
  default:
    if let id { send(["id": id, "error": ["code": -32601, "message": "No method \(method)"]]) }
  }
}
