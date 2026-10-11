import Foundation
import CryptoKit

typealias InferenceObject = [String: Any]
func inferenceObject(_ value: Any?) -> InferenceObject { value as? InferenceObject ?? [:] }
func inferenceObjects(_ value: Any?) -> [InferenceObject] { value as? [InferenceObject] ?? [] }
func inferenceJSONString(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
func inferenceContent(_ message: InferenceObject) -> [InferenceObject] {
  if let value = message["content"] as? String { return [["type": "text", "text": value]] }
  return inferenceObjects(message["content"])
}
func inferenceText(_ message: InferenceObject) -> String { inferenceContent(message).compactMap { $0["text"] as? String }.joined(separator: "\n") }

struct InferenceRequestBuilder {
  let connection: InferenceConnection
  let model: InferenceModel
  func request(_ input: InferenceObject, secret: String, accountID: String? = nil) throws -> URLRequest {
    try connection.validate()
    guard model.id == connection.modelID, model.provider == connection.provider else { throw InferenceError.modelUnavailable }
    if !connection.provider.hasPrefix("local-server-") { try InferenceModelPolicy.validate(model, provider: connection.provider) }
    let context = inferenceObject(input["context"]), options = inferenceObject(input["options"])
    let compat = inferenceObject(model.metadata["compat"]?.value)
    let transcript = inferenceObjects(context["messages"])
    var system = [String](), sections = [String: String](), sectionOrder = [String](), tools = [String: InferenceObject](), toolOrder = [String]()
    if let text = context["systemPrompt"] as? String, !text.isEmpty { system.append(text) }
    for tool in inferenceObjects(context["tools"]) { if let name = tool["name"] as? String { toolOrder.append(name); tools[name] = tool } }
    for message in transcript where message["role"] as? String == "system" {
      let text = inferenceText(message); if !text.isEmpty { system.append(text) }
      for (name, value) in inferenceObject(message["sections"]) {
        if let text = value as? String { if sections[name] == nil { sectionOrder.append(name) }; sections[name] = text }
        else { sections.removeValue(forKey: name); sectionOrder.removeAll { $0 == name } }
      }
      for tool in inferenceObjects(message["toolsRemoved"]) { if let name = tool["name"] as? String { tools.removeValue(forKey: name); toolOrder.removeAll { $0 == name } } }
      for tool in inferenceObjects(message["toolsAdded"]) { if let name = tool["name"] as? String { if tools[name] == nil { toolOrder.append(name) }; tools[name] = tool } }
    }
    system.append(contentsOf: sectionOrder.compactMap { sections[$0] })
    let prompt = system.joined(separator: "\n\n"), inventory = toolOrder.compactMap { tools[$0] }
    let messages = transcript.filter { $0["role"] as? String != "system" && !["error", "aborted"].contains($0["stopReason"] as? String ?? "") }
    var body: InferenceObject = ["model": model.id, "stream": true]
    let maxTokens = min(options["maxTokens"] as? Int ?? model.maxTokens, model.maxTokens)
    guard maxTokens > 0 else { throw InferenceError.invalidConfiguration }
    let requestedReasoning = options["reasoning"] as? String
    let reasoning: String? = requestedReasoning.flatMap { value in
      guard value != "off", model.reasoning else { return nil }
      if let map = model.thinkingLevelMap { return map[value] ?? nil }
      return value
    }
    let codex = model.api == "openai-codex-responses"
    let session = options["sessionId"] as? String ?? inferenceObject(input["scope"])["conversationID"] as? String
    let sessionID = session.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    var path: String
    switch model.api {
    case "openai-responses", "openai-codex-responses":
      path = codex ? "codex/responses" : "responses"; body["store"] = false
      if codex {
        body["instructions"] = prompt.isEmpty ? "You are a helpful assistant." : prompt
        body["text"] = ["verbosity": "low"]; body["include"] = ["reasoning.encrypted_content"]
        body["tool_choice"] = "auto"; body["parallel_tool_calls"] = true
        body["prompt_cache_key"] = sessionID
      } else {
        body["max_output_tokens"] = maxTokens
        if !prompt.isEmpty { body["instructions"] = prompt }
      }
      body["input"] = try responsesMessages(messages)
      if !inventory.isEmpty { body["tools"] = inventory.map { ["type": "function", "name": $0["name"] ?? "", "description": $0["description"] ?? "", "parameters": $0["parameters"] ?? [:], "strict": false] } }
      if codex, !inventory.isEmpty { body["tools"] = inventory.map { ["type": "function", "name": $0["name"] ?? "", "description": $0["description"] ?? "", "parameters": $0["parameters"] ?? [:], "strict": NSNull()] } }
      if let reasoning { body["reasoning"] = ["effort": reasoning, "summary": "auto"]; body["include"] = ["reasoning.encrypted_content"] }
      else if codex, model.reasoning {
        if let map = model.thinkingLevelMap, map.keys.contains("off") { if let off = map["off"] ?? nil { body["reasoning"] = ["effort": off] } }
        else { body["reasoning"] = ["effort": "none"] }
      }
    case "anthropic-messages":
      path = "v1/messages"; body["max_tokens"] = maxTokens; body["messages"] = try anthropicMessages(messages)
      if !prompt.isEmpty { body["system"] = prompt }
      if !inventory.isEmpty { body["tools"] = inventory.map { ["name": $0["name"] ?? "", "description": $0["description"] ?? "", "input_schema": $0["parameters"] ?? [:]] } }
      if let reasoning {
        if compat["forceAdaptiveThinking"] as? Bool == true || compat["supportsMidConvoEffort"] as? Bool == true {
          body["thinking"] = ["type": "adaptive"]; body["output_config"] = ["effort": reasoning]
        } else {
          let budgets = ["minimal": 1024, "low": 2048, "medium": 8192, "high": 16384, "xhigh": 24576, "max": 32768]
          body["thinking"] = ["type": "enabled", "budget_tokens": min(budgets[reasoning] ?? 8192, maxTokens - 1)]
        }
      }
    case "openai-completions":
      path = "chat/completions"; body[compat["maxTokensField"] as? String ?? "max_tokens"] = maxTokens
      body["messages"] = try chatMessages(messages, system: prompt)
      if compat["supportsUsageInStreaming"] as? Bool != false { body["stream_options"] = ["include_usage": true] }
      if !inventory.isEmpty { body["tools"] = inventory.map { ["type": "function", "function": ["name": $0["name"] ?? "", "description": $0["description"] ?? "", "parameters": $0["parameters"] ?? [:]]] } }
      if let reasoning {
        if model.provider == "openrouter" { body["reasoning"] = ["effort": reasoning] }
        else { body["reasoning_effort"] = reasoning; if compat["thinkingFormat"] as? String == "deepseek" { body["thinking"] = ["type": "enabled"] } }
      }
    default: throw InferenceError.modelUnavailable
    }
    if let temperature = options["temperature"] as? Double, reasoning == nil, !codex { body["temperature"] = temperature }
    var base = connection.provider.hasPrefix("local-server-") ? try InferenceURLPolicy.tailnet(connection.baseURL ?? "") : try cloudURL(model.baseUrl)
    if connection.provider.hasPrefix("local-server-"), base.path.isEmpty || base.path == "/" { base.appendPathComponent("v1") }
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("WovenMatter/1 iOS", forHTTPHeaderField: "User-Agent")
    if model.api == "anthropic-messages" {
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      if connection.provider == "claude-subscription" {
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      } else { request.setValue(secret, forHTTPHeaderField: "x-api-key") }
    } else { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
    if codex {
      guard let accountID, !accountID.isEmpty, !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw InferenceOAuthError.signInRequired }
      request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
      request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
      request.setValue("wovenmatter", forHTTPHeaderField: "originator")
      request.setValue(sessionID, forHTTPHeaderField: "session-id")
      request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
    }
    if ["opencode", "opencode-go"].contains(model.provider), let scope = input["scope"] as? InferenceObject, let session = scope["conversationID"] as? String {
      request.setValue(session, forHTTPHeaderField: "x-opencode-session")
    }
    return request
  }
  private func cloudURL(_ value: String) throws -> URL {
    try InferenceModelPolicy.validate(model, provider: connection.provider)
    guard let url = URL(string: value) else { throw InferenceError.invalidEndpoint }
    return url
  }
  private func image(_ block: InferenceObject) throws -> (String, String) {
    guard model.input.contains("image") else { throw InferenceError.unsupportedImageInput }
    guard let mime = block["mimeType"] as? String, mime.hasPrefix("image/"),
      let data = block["data"] as? String, Data(base64Encoded: data) != nil else { throw InferenceError.invalidConfiguration }
    return (mime, data)
  }
  private func responsesMessages(_ messages: [InferenceObject]) throws -> [InferenceObject] {
    var result = [InferenceObject]()
    for message in messages {
      let role = message["role"] as? String ?? ""
      if role == "toolResult" {
        let text = inferenceText(message), images = inferenceContent(message).filter { $0["type"] as? String == "image" }
        var output: Any = text
        if !images.isEmpty {
          var blocks: [InferenceObject] = text.isEmpty ? [] : [["type": "input_text", "text": text]]
          for block in images {
            let (mime, data) = try image(block)
            blocks.append(["type": "input_image", "detail": "auto", "image_url": "data:\(mime);base64,\(data)"])
          }
          output = blocks
        }
        result.append(["type": "function_call_output", "call_id": callID(message["toolCallId"] as? String ?? ""), "output": output]); continue
      }
      var content = [InferenceObject]()
      for block in inferenceContent(message) {
        switch block["type"] as? String {
        case "text":
          if role == "assistant", message["wovenInferenceConnectionID"] as? String == connection.id,
            message["provider"] as? String == model.provider, message["api"] as? String == model.api, message["model"] as? String == model.id,
            let raw = block["textSignature"] as? String, raw.utf8.count <= 2048, let data = raw.data(using: .utf8),
            let signature = try? JSONSerialization.jsonObject(with: data) as? InferenceObject, signature["v"] as? Int == 1,
            let originalID = signature["id"] as? String, !originalID.isEmpty, originalID.utf8.count <= 512 {
            if !content.isEmpty { result.append(["role": role, "content": content]); content = [] }
            let id = originalID.count <= 64 ? originalID : "msg_" + SHA256.hash(data: Data(originalID.utf8)).prefix(24).map { String(format: "%02x", $0) }.joined()
            let text: InferenceObject = ["type": "output_text", "text": block["text"] ?? "", "annotations": []]
            var item: InferenceObject = ["type": "message", "role": "assistant", "id": id, "status": "completed", "content": [text]]
            if let phase = signature["phase"] as? String, ["commentary", "final_answer"].contains(phase) { item["phase"] = phase }
            if let last = result.last, last["type"] as? String == "message", last["id"] as? String == id,
              last["phase"] as? String == item["phase"] as? String {
              result[result.count - 1]["content"] = inferenceObjects(last["content"]) + [text]
            } else { result.append(item) }
          } else { content.append(["type": role == "assistant" ? "output_text" : "input_text", "text": block["text"] ?? ""]) }
        case "image": let (mime, data) = try image(block); content.append(["type": "input_image", "image_url": "data:\(mime);base64,\(data)"])
        case "toolCall":
          if !content.isEmpty { result.append(["role": role, "content": content]); content = [] }
          result.append(["type": "function_call", "call_id": callID(block["id"] as? String ?? ""), "name": block["name"] ?? "", "arguments": try inferenceJSONString(inferenceObject(block["arguments"]))])
        case "thinking":
          if message["wovenInferenceConnectionID"] as? String == connection.id,
            let signature = block["thinkingSignature"] as? String, let data = signature.data(using: .utf8),
            let item = try? JSONSerialization.jsonObject(with: data) as? InferenceObject, item["type"] as? String == "reasoning" { result.append(item) }
        default: break
        }
      }
      if !content.isEmpty { result.append(["role": role, "content": content]) }
    }
    return result
  }
  private func anthropicMessages(_ messages: [InferenceObject]) throws -> [InferenceObject] {
    var result = [InferenceObject]()
    for message in messages {
      let role = message["role"] as? String ?? ""
      var content = [InferenceObject]()
      for block in inferenceContent(message) {
        switch block["type"] as? String {
        case "text": content.append(["type": "text", "text": block["text"] ?? ""])
        case "image": let (mime, data) = try image(block); content.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": data]])
        case "toolCall": content.append(["type": "tool_use", "id": callID(block["id"] as? String ?? ""), "name": block["name"] ?? "", "input": inferenceObject(block["arguments"])])
        case "thinking":
          if message["wovenInferenceConnectionID"] as? String == connection.id, let signature = block["thinkingSignature"] as? String {
            if block["redacted"] as? Bool == true { content.append(["type": "redacted_thinking", "data": signature]) }
            else { content.append(["type": "thinking", "thinking": block["thinking"] ?? "", "signature": signature]) }
          }
        default: break
        }
      }
      let normalizedRole = role == "assistant" ? "assistant" : "user"
      if role == "toolResult" { content = [["type": "tool_result", "tool_use_id": callID(message["toolCallId"] as? String ?? ""), "content": content, "is_error": message["isError"] as? Bool ?? false]] }
      if !content.isEmpty {
        if let last = result.last, last["role"] as? String == normalizedRole {
          result[result.count - 1]["content"] = inferenceObjects(last["content"]) + content
        } else { result.append(["role": normalizedRole, "content": content]) }
      }
    }
    return result
  }
  private func chatMessages(_ messages: [InferenceObject], system: String) throws -> [InferenceObject] {
    var result: [InferenceObject] = system.isEmpty ? [] : [["role": "system", "content": system]]
    let compat = inferenceObject(model.metadata["compat"]?.value)
    let requiresAssistantAfterToolResult = compat["requiresAssistantAfterToolResult"] as? Bool == true
    var lastRole: String?
    var toolImages = [InferenceObject]()
    func appendToolImages() {
      guard !toolImages.isEmpty else { return }
      // Chat requires every parallel tool call to receive its result before a user image message.
      if requiresAssistantAfterToolResult {
        result.append(["role": "assistant", "content": "I have processed the tool results."])
      }
      result.append(["role": "user", "content": [["type": "text", "text": "Attached image(s) from tool result:"]] + toolImages])
      toolImages.removeAll(keepingCapacity: true)
      lastRole = "user"
    }
    for message in messages {
      let role = message["role"] as? String ?? ""
      if role == "toolResult" {
        let text = inferenceText(message), images = inferenceContent(message).filter { $0["type"] as? String == "image" }
        var value: InferenceObject = ["role": "tool", "tool_call_id": callID(message["toolCallId"] as? String ?? ""),
          "content": text.isEmpty && !images.isEmpty ? "(see attached image)" : text]
        if compat["requiresToolResultName"] as? Bool == true, let name = message["toolName"] as? String { value["name"] = name }
        result.append(value)
        for block in images {
          let (mime, data) = try image(block)
          toolImages.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data)"]])
        }
        lastRole = role
        continue
      }
      appendToolImages()
      if requiresAssistantAfterToolResult, lastRole == "toolResult", role == "user" {
        result.append(["role": "assistant", "content": "I have processed the tool results."])
      }
      lastRole = role
      var content = [InferenceObject](), calls = [InferenceObject]()
      var thinking = ""
      var reasoningDetails = [InferenceObject]()
      for block in inferenceContent(message) {
        switch block["type"] as? String {
        case "text": content.append(["type": "text", "text": block["text"] ?? ""])
        case "image": let (mime, data) = try image(block); content.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data)"]])
        case "toolCall": calls.append(["type": "function", "id": callID(block["id"] as? String ?? ""), "function": ["name": block["name"] ?? "", "arguments": try inferenceJSONString(inferenceObject(block["arguments"]))]])
        case "thinking":
          thinking += block["thinking"] as? String ?? ""
          if message["wovenInferenceConnectionID"] as? String == connection.id,
             let signature = block["thinkingSignature"] as? String,
             let details = try? JSONSerialization.jsonObject(with: Data(signature.utf8)) as? [InferenceObject] { reasoningDetails += details }
        default: break
        }
      }
      var value: InferenceObject = ["role": role, "content": content.isEmpty ? NSNull() : content]
      if role == "assistant", content.isEmpty, requiresAssistantAfterToolResult { value["content"] = "" }
      if !calls.isEmpty { value["tool_calls"] = calls }
      if !reasoningDetails.isEmpty { value["reasoning_details"] = reasoningDetails }
      if role == "assistant", inferenceObject(model.metadata["compat"]?.value)["requiresReasoningContentOnAssistantMessages"] as? Bool == true { value["reasoning_content"] = "" }
      if !thinking.isEmpty, message["wovenInferenceConnectionID"] as? String == connection.id { value["reasoning_content"] = thinking }
      result.append(value)
    }
    appendToolImages()
    return result
  }
  private func callID(_ value: String) -> String { String(value.split(separator: "|", maxSplits: 1).first ?? "") }
}
