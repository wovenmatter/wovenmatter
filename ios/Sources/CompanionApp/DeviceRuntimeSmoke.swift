#if DEBUG
import Foundation
import CompanionClient
import CompanionInference
import PiDurableRuntime

/// Actual bundled SDK + native local notes, driven solely by synthetic inference.
private actor QuickChatSmokeHost {
  var calls = 0
  var advertised: Set<String> = []
  func inference(_ request: String, emit: @escaping @Sendable (String) -> Void) throws {
    calls += 1
    let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
    let context = value?["context"] as? [String: Any] ?? [:]
    advertised.formUnion((context["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    let finished = (context["messages"] as? [[String: Any]] ?? []).contains { $0["role"] as? String == "toolResult" }
    let content: [[String: Any]] = finished ? [["type": "text", "text": "Created your Quick Chat note."]] :
      [["type": "toolCall", "id": "smoke-note", "name": "woven_notes_create", "arguments": ["title": "Quick Chat smoke", "kind": "note"]]]
    let message: [String: Any] = ["role": "assistant", "content": content, "api": "openai-responses", "provider": "controlled", "model": "smoke",
      "usage": ["input": 10, "output": 8, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 18, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]],
      "stopReason": finished ? "stop" : "toolUse", "timestamp": Date().timeIntervalSince1970 * 1000]
    emit(String(decoding: try JSONSerialization.data(withJSONObject: ["type": "done", "reason": finished ? "stop" : "toolUse", "message": message]), as: UTF8.self))
  }
}

@MainActor enum DeviceRuntimeSmoke {
  static var enabled: Bool { ProcessInfo.processInfo.environment["WOVENMATTER_DEVICE_RUNTIME_SMOKE"] == "1" }
  private static var started = false
  static func run() async {
    guard enabled, !started else { return }; started = true
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-chat-smoke-" + UUID().uuidString)
    var report: [String: Any] = [:]
    do {
      let model = CompanionModel()
      model.store = try MobileStore(file: root.appendingPathComponent("library.json"))
      model.executionDirectory = root.appendingPathComponent("execution")
      await model.reload()
      let id = UUID().uuidString.lowercased(), requestID = UUID().uuidString.lowercased()
      let descriptor = "{\"id\":\"smoke\",\"name\":\"Controlled model\",\"api\":\"openai-responses\",\"provider\":\"controlled\",\"baseUrl\":\"https://invalid.test\",\"reasoning\":false,\"input\":[\"text\"],\"contextWindow\":10000,\"maxTokens\":1024,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}}"
      model.executionRecords[id] = .init(id: id, title: "Quick Chat smoke", connectionID: "fixture", modelJSON: descriptor, status: "ready", updatedAt: "")
      let host = QuickChatSmokeHost()
      let runtime = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("runtime"),
        configuration: .init(conversationID: id, modelJSON: descriptor, toolsJSON: try model.toolsJSON(for: model.executionRecords[id]!), quickChat: true),
        inference: { try await host.inference($0, emit: $1) }, tool: { try await model.performDeviceTool($0) })
      try await runtime.open()
      let accepted = try CompanionModel.executionObject(await runtime.submit(text: "Create a note", requestID: requestID))
      guard let submissionID = accepted["id"] as? Int else { throw CocoaError(.coderReadCorrupt) }
      _ = try await runtime.wait(submissionID: submissionID)
      let calls = await host.calls
      _ = try await runtime.submit(text: "Create a note", requestID: requestID)
      await model.reload()
      guard model.notes.count == 1, model.notes.first?.title == "Quick Chat smoke", await host.calls == calls,
        await host.advertised.isDisjoint(with: ["codemode", "subagent", "execute_command", "write_file", "woven_goals_set", "woven_executor_execute"]) else {
        throw CocoaError(.coderInvalidValue)
      }
      try await runtime.close()
      report = ["quickChatNativeNotes": true, "quickChatNoCodeOrSubagents": true, "quickChatReceiptReplay": true, "success": true]
    } catch { report = ["success": false, "error": error.localizedDescription] }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
      try? data.write(to: documents.appendingPathComponent("runtime-smoke.json"), options: .atomic)
    }
    try? FileManager.default.removeItem(at: root)
  }
}
#endif
