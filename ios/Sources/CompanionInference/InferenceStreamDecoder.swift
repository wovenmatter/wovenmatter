import Foundation

/// Converts transport events into Pi's AssistantMessageEvent contract. A tool is exposed only after valid complete arguments.
final class InferenceStreamDecoder {
  let model: InferenceModel
  let connectionID: String
  let emit: @Sendable (String) -> Void
  private var message: InferenceObject
  private var content = [InferenceObject]()
  private var indices = [String: Int]()
  private var argumentBuffers = [Int: String]()
  private var closedBlocks = Set<Int>()
  private var reasoningDetails = [InferenceObject]()
  private var started = false
  private var providerFinished = false
  private(set) var terminal = false
  init(model: InferenceModel, connectionID: String, emit: @escaping @Sendable (String) -> Void) {
    self.model = model; self.connectionID = connectionID; self.emit = emit
    message = ["role": "assistant", "api": model.api, "provider": model.provider, "model": model.id,
      "wovenInferenceConnectionID": connectionID, "content": [], "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      "stopReason": "stop", "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
        "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]]
  }
  private func event(_ type: String, _ fields: InferenceObject = [:]) throws {
    message["content"] = content
    var value = fields; value["type"] = type
    if !["done", "error"].contains(type) { value["partial"] = message }
    emit(try inferenceJSONString(value))
  }
  private func start() throws {
    guard !started else { return }; started = true; try event("start")
  }
  private func index(_ key: String, block: InferenceObject) throws -> Int {
    if let current = indices[key] { return current }
    let current = content.count; indices[key] = current; content.append(block)
    let type = block["type"] as? String ?? "text"
    try event(type == "toolCall" ? "toolcall_start" : "\(type)_start", ["contentIndex": current])
    return current
  }
  private func delta(_ text: String, key: String, kind: String) throws {
    guard !text.isEmpty else { return }
    let index = try index(key, block: ["type": kind, kind: ""])
    content[index][kind] = (content[index][kind] as? String ?? "") + text
    try event("\(kind)_delta", ["contentIndex": index, "delta": text])
  }
  private func toolDelta(_ text: String, index: Int) throws {
    argumentBuffers[index, default: ""] += text
    try event("toolcall_delta", ["contentIndex": index, "delta": text])
  }
  private func close(_ index: Int) throws {
    guard !closedBlocks.contains(index) else { return }
    closedBlocks.insert(index)
    let kind = content[index]["type"] as? String ?? "text"
    if kind == "toolCall" {
      if let buffer = argumentBuffers[index], !buffer.isEmpty {
        guard let data = buffer.data(using: .utf8), let arguments = try JSONSerialization.jsonObject(with: data) as? InferenceObject
        else { throw InferenceError.malformedResponse }
        content[index]["arguments"] = arguments
      }
      guard let id = content[index]["id"] as? String, !id.isEmpty, let name = content[index]["name"] as? String, !name.isEmpty else { throw InferenceError.malformedResponse }
      try event("toolcall_end", ["contentIndex": index, "toolCall": content[index]])
    } else { try event("\(kind)_end", ["contentIndex": index, "content": content[index][kind] ?? ""]) }
  }
  func consume(_ payload: String) throws {
    if terminal { return }
    if payload == "[DONE]" { try finish(); return }
    guard let data = payload.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? InferenceObject else { throw InferenceError.malformedResponse }
    if value["error"] != nil || value["type"] as? String == "error" { throw InferenceError.malformedResponse }
    try start()
    switch model.api {
    case "openai-responses": try responses(value)
    case "anthropic-messages": try anthropic(value)
    case "openai-completions": try chat(value)
    default: throw InferenceError.modelUnavailable
    }
  }
  func finish() throws {
    guard !terminal else { return }
    guard providerFinished else { throw InferenceError.interrupted }
    for i in content.indices { try close(i) }
    message["content"] = content
    if content.contains(where: { $0["type"] as? String == "toolCall" }), message["stopReason"] as? String == "stop" { message["stopReason"] = "toolUse" }
    terminal = true
    try event("done", ["reason": message["stopReason"] ?? "stop", "message": message])
  }
  private func usage(input: Int, output: Int, read: Int = 0, write: Int = 0, reasoning: Int? = nil) {
    var rates = model.cost
    let contextTokens = input + read + write
    for tier in inferenceObjects(inferenceObject(model.metadata["cost"]?.value)["tiers"]).sorted(by: { ($0["inputTokensAbove"] as? Double ?? 0) < ($1["inputTokensAbove"] as? Double ?? 0) }) {
      if Double(contextTokens) > (tier["inputTokensAbove"] as? Double ?? .infinity) {
        for key in ["input", "output", "cacheRead", "cacheWrite"] { if let rate = tier[key] as? Double { rates[key] = rate } }
      }
    }
    let amounts: [String: Double] = ["input": Double(max(0, input)) * (rates["input"] ?? 0) / 1_000_000,
      "output": Double(output) * (rates["output"] ?? 0) / 1_000_000,
      "cacheRead": Double(read) * (rates["cacheRead"] ?? 0) / 1_000_000,
      "cacheWrite": Double(write) * (rates["cacheWrite"] ?? 0) / 1_000_000]
    var cost = amounts; cost["total"] = amounts.values.reduce(0, +)
    var usage: InferenceObject = ["input": max(0, input), "output": output, "cacheRead": read, "cacheWrite": write,
      "totalTokens": max(0, input) + output + read + write, "cost": cost]
    if let reasoning { usage["reasoning"] = reasoning }
    message["usage"] = usage
  }
  private func responses(_ value: InferenceObject) throws {
    let type = value["type"] as? String ?? ""
    let output = value["output_index"] as? Int ?? 0
    let part = value["content_index"] as? Int ?? 0
    if type == "response.created" {
      let response = inferenceObject(value["response"]); message["responseId"] = response["id"]; message["responseModel"] = response["model"]
    } else if type == "response.output_text.delta" {
      try delta(value["delta"] as? String ?? "", key: "text:\(output):\(part)", kind: "text")
    } else if type == "response.reasoning_summary_text.delta" || type == "response.reasoning_text.delta" {
      try delta(value["delta"] as? String ?? "", key: "thinking:\(output)", kind: "thinking")
    } else if type == "response.output_item.added" {
      let item = inferenceObject(value["item"])
      if item["type"] as? String == "function_call" {
        _ = try index("tool:\(output)", block: ["type": "toolCall", "id": item["call_id"] ?? "", "name": item["name"] ?? "", "arguments": [:]])
      }
    } else if type == "response.function_call_arguments.delta" {
      guard let i = indices["tool:\(output)"] else { throw InferenceError.malformedResponse }
      try toolDelta(value["delta"] as? String ?? "", index: i)
    } else if type == "response.completed" || type == "response.incomplete" {
      let response = inferenceObject(value["response"])
      guard ["completed", "incomplete"].contains(response["status"] as? String ?? "") else { throw InferenceError.malformedResponse }
      // Completed output is authoritative, including encrypted reasoning records and tool identities.
      for (offset, item) in inferenceObjects(response["output"]).enumerated() {
        switch item["type"] as? String {
        case "message":
          for (part, block) in inferenceObjects(item["content"]).enumerated() {
            if block["type"] as? String == "output_text" {
              let i = try index("text:\(offset):\(part)", block: ["type": "text", "text": ""]); content[i]["text"] = block["text"] ?? ""
            } else if block["type"] as? String == "refusal" {
              let i = try index("text:\(offset):\(part)", block: ["type": "text", "text": ""]); content[i]["text"] = block["refusal"] ?? ""
            }
          }
        case "function_call":
          let i = try index("tool:\(offset)", block: ["type": "toolCall", "id": item["call_id"] ?? "", "name": item["name"] ?? "", "arguments": [:]])
          argumentBuffers[i] = item["arguments"] as? String ?? "{}"
        case "reasoning":
          let i = try index("thinking:\(offset)", block: ["type": "thinking", "thinking": ""])
          content[i]["thinking"] = inferenceObjects(item["summary"]).compactMap { $0["text"] as? String }.joined(separator: "\n")
          content[i]["thinkingSignature"] = try inferenceJSONString(item)
        default: break
        }
      }
      let reported = inferenceObject(response["usage"]), input = reported["input_tokens"] as? Int ?? 0
      let read = inferenceObject(reported["input_tokens_details"])["cached_tokens"] as? Int ?? 0
      usage(input: input - read, output: reported["output_tokens"] as? Int ?? 0, read: read,
        reasoning: inferenceObject(reported["output_tokens_details"])["reasoning_tokens"] as? Int)
      message["responseId"] = response["id"]; message["responseModel"] = response["model"]
      message["stopReason"] = type == "response.incomplete" ? "length" : "stop"
      providerFinished = true; try finish()
    } else if ["response.failed", "response.cancelled"].contains(type) { throw InferenceError.interrupted }
  }
  private func anthropic(_ value: InferenceObject) throws {
    let type = value["type"] as? String ?? "", offset = value["index"] as? Int ?? 0
    if type == "message_start" {
      let response = inferenceObject(value["message"]), reported = inferenceObject(response["usage"])
      message["responseId"] = response["id"]; message["responseModel"] = response["model"]
      usage(input: reported["input_tokens"] as? Int ?? 0, output: reported["output_tokens"] as? Int ?? 0,
        read: reported["cache_read_input_tokens"] as? Int ?? 0, write: reported["cache_creation_input_tokens"] as? Int ?? 0)
    } else if type == "content_block_start" {
      let block = inferenceObject(value["content_block"]), kind = block["type"] as? String
      if kind == "tool_use" {
        _ = try index("block:\(offset)", block: ["type": "toolCall", "id": block["id"] ?? "", "name": block["name"] ?? "", "arguments": inferenceObject(block["input"])])
      } else if kind == "thinking" || kind == "redacted_thinking" {
        let i = try index("block:\(offset)", block: ["type": "thinking", "thinking": block["thinking"] ?? ""])
        if kind == "redacted_thinking" { content[i]["redacted"] = true; content[i]["thinkingSignature"] = block["data"] }
      } else if kind == "text" { _ = try index("block:\(offset)", block: ["type": "text", "text": block["text"] ?? ""]) }
      else { throw InferenceError.malformedResponse }
    } else if type == "content_block_delta" {
      guard let i = indices["block:\(offset)"] else { throw InferenceError.malformedResponse }
      let change = inferenceObject(value["delta"])
      if change["type"] as? String == "input_json_delta" { try toolDelta(change["partial_json"] as? String ?? "", index: i) }
      else if change["type"] as? String == "signature_delta" { content[i]["thinkingSignature"] = (content[i]["thinkingSignature"] as? String ?? "") + (change["signature"] as? String ?? "") }
      else {
        let kind = change["type"] as? String == "thinking_delta" ? "thinking" : "text"
        try delta(change[kind] as? String ?? "", key: "block:\(offset)", kind: kind)
      }
    } else if type == "content_block_stop" {
      guard let i = indices["block:\(offset)"] else { throw InferenceError.malformedResponse }; try close(i)
    } else if type == "message_delta" {
      let reason = inferenceObject(value["delta"])["stop_reason"] as? String ?? ""
      message["rawStopReason"] = reason
      message["stopReason"] = reason == "tool_use" ? "toolUse" : ["max_tokens", "model_context_window_exceeded"].contains(reason) ? "length" : "stop"
      let previous = inferenceObject(message["usage"]), reported = inferenceObject(value["usage"])
      usage(input: previous["input"] as? Int ?? 0, output: reported["output_tokens"] as? Int ?? 0,
        read: previous["cacheRead"] as? Int ?? 0, write: previous["cacheWrite"] as? Int ?? 0)
      providerFinished = !reason.isEmpty
    } else if type == "message_stop" { try finish() }
  }
  private func chat(_ value: InferenceObject) throws {
    message["responseId"] = value["id"]; message["responseModel"] = value["model"]
    if let reported = value["usage"] as? InferenceObject {
      let read = inferenceObject(reported["prompt_tokens_details"])["cached_tokens"] as? Int ?? 0
      usage(input: (reported["prompt_tokens"] as? Int ?? 0) - read, output: reported["completion_tokens"] as? Int ?? 0, read: read,
        reasoning: inferenceObject(reported["completion_tokens_details"])["reasoning_tokens"] as? Int)
    }
    guard let choice = inferenceObjects(value["choices"]).first else { return }
    let change = inferenceObject(choice["delta"])
    try delta(change["content"] as? String ?? "", key: "text", kind: "text")
    try delta(change["reasoning_content"] as? String ?? change["reasoning"] as? String ?? "", key: "thinking", kind: "thinking")
    for detail in inferenceObjects(change["reasoning_details"]) {
      guard let type = detail["type"] as? String, ["reasoning.text", "reasoning.summary", "reasoning.encrypted"].contains(type) else { continue }
      let i = try index("thinking", block: ["type": "thinking", "thinking": ""])
      let field = type == "reasoning.text" ? "text" : "summary"
      if type != "reasoning.encrypted", let previous = reasoningDetails.last, previous["type"] as? String == type {
        let last = reasoningDetails.count - 1
        reasoningDetails[last][field] = (previous[field] as? String ?? "") + (detail[field] as? String ?? "")
        for key in ["signature", "id", "format", "index"] where reasoningDetails[last][key] == nil { reasoningDetails[last][key] = detail[key] }
      } else { reasoningDetails.append(detail) }
      content[i]["thinkingSignature"] = try inferenceJSONString(reasoningDetails)
    }
    for tool in inferenceObjects(change["tool_calls"]) {
      let offset = tool["index"] as? Int ?? 0, function = inferenceObject(tool["function"])
      let i = try index("tool:\(offset)", block: ["type": "toolCall", "id": "", "name": "", "arguments": [:]])
      if let id = tool["id"] as? String { content[i]["id"] = (content[i]["id"] as? String ?? "") + id }
      if let name = function["name"] as? String { content[i]["name"] = (content[i]["name"] as? String ?? "") + name }
      if let arguments = function["arguments"] as? String { try toolDelta(arguments, index: i) }
    }
    if let reason = choice["finish_reason"] as? String {
      providerFinished = true; message["rawStopReason"] = reason
      message["stopReason"] = reason == "length" ? "length" : reason == "tool_calls" ? "toolUse" : "stop"
    }
  }
}
