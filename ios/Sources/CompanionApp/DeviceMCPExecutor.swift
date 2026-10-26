import Foundation
import CompanionClient
import PiDurableRuntime
import WovenMatterCompanion

@MainActor enum DeviceMCPExecutorJobs {
  static var tasks: [String: Task<Void, Never>] = [:]
  static var owners: [String: String] = [:]
  static func cancelWithoutContinuation(_ hasContinuation: (String) -> Bool) {
    for (id, owner) in owners where !hasContinuation(owner) { tasks[id]?.cancel() }
  }
  static func hasUncontinuedJobs(_ hasContinuation: (String) -> Bool) -> Bool { owners.values.contains { !hasContinuation($0) } }

}
extension CompanionModel {
  func executeDeviceExecutorTool(_ c: WovenMatterToolCommand, request: WovenMatterToolRequest, conversationID: String) async throws -> WovenMatterToolResponse {
    try Task.checkCancellation()
    guard let store, let record = executionRecords[conversationID] else { throw WorkspaceToolError.notFound("The local execution owner is unavailable.") }
    // Native capabilities are always available; MCP groups follow Tool Access.
    // Executor cannot call itself recursively or activate a disabled MCP group.
    let available = Self.deviceToolDefinitions.filter { tool in
      guard let name = tool["name"] as? String, !name.hasPrefix("woven_executor_") else { return false }
      return Self.deviceToolEnabled(name, selection: record.enabledTools)
    }
    if c.action == "search" {
      let query = c.options["query"] ?? "", limit = try c.integer("limit", default: 50, range: 1...100)
      let tools = available.filter { query.isEmpty || ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(query) || ($0["description"] as? String ?? "").localizedCaseInsensitiveContains(query) }.prefix(limit)
      let value = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONSerialization.data(withJSONObject: Array(tools)))
      return .init(result: .object(["tools": value, "scope": .string("device"), "invocation": .string("await tools.TOOL_NAME(arguments)")]), requestID: request.requestID)
    }
    if c.action == "skills" {
      return .init(result: .object(["skills": .array([]), "scope": .string("device"), "help": .string("Use search to inspect selected native device tools. Executor programs use async JavaScript, tools.NAME(arguments), text(value), store(key, value), and await checkpoint(). Central app integrations remain available through target central.")]), requestID: request.requestID)
    }
    if c.action == "execute" {
      let code = try c.required("code")
      let job = try await store.createExecutorJob(id: request.requestID, sessionID: conversationID, code: code)
      if try await store.claimExecutorJobStart(id: job.id, sessionID: conversationID) {
        let id = job.id, policy = record.executionPolicy ?? deviceAgentDefaults.executionPolicy ?? .init()
        DeviceMCPExecutorJobs.owners[id] = conversationID
        beginFallbackExecutionBackgroundTask()
        DeviceMCPExecutorJobs.tasks[id] = Task { @MainActor [weak self] in
          defer {
            DeviceMCPExecutorJobs.tasks.removeValue(forKey: id)
            DeviceMCPExecutorJobs.owners.removeValue(forKey: id)
            self?.endIdleExecutionBackgroundTask()
          }
          guard let self else { return }
          do {
            try Task.checkCancellation()
            guard try await store.executorJob(id: id, sessionID: conversationID).state == "starting" else { throw CancellationError() }
            try await store.updateExecutorJob(id: id, state: "running")
            try Task.checkCancellation()
            let input = try Self.toolJSON(["source": code, "tools": available])
            var callIndex = 0
            let result = try await PiDeviceCodeExecutor.run(requestJSON: input, policy: policy,
              checkpoint: { checkpoint in try await store.saveExecutorCheckpoint(id: id, checkpoint: checkpoint) },
              tool: { [weak self] name, arguments in
                guard let self else { throw CancellationError() }
                callIndex += 1
                let args = try Self.executionObject(arguments)
                let payload = try Self.toolJSON(["name": name, "arguments": args, "conversationID": conversationID,
                  "taskID": "executor:" + id, "toolCallID": String(callIndex)])
                return try await self.performDeviceTool(payload)
              })
            try await store.updateExecutorJob(id: id, state: "completed", result: result)
          } catch {
            try? await store.updateExecutorJob(id: id, state: Task.isCancelled ? "cancelled" : "interrupted", error: error.localizedDescription)
          }
        }
      }
      return .init(result: .object(["id": .string(job.id), "state": .string(job.state)]), requestID: request.requestID)
    }
    let id = try c.required("id", allowPositional: true)
    var job = try await store.executorJob(id: id, sessionID: conversationID)
    if c.action == "cancel" {
      DeviceMCPExecutorJobs.tasks[id]?.cancel()
      if ["queued", "starting", "running"].contains(job.state) { try await store.updateExecutorJob(id: id, state: "cancelled"); job = try await store.executorJob(id: id, sessionID: conversationID) }
    } else if ["queued", "starting", "running"].contains(job.state), DeviceMCPExecutorJobs.tasks[id] == nil {
      try await store.updateExecutorJob(id: id, state: "interrupted", error: "This execution was interrupted. Its effects will not be replayed automatically.")
      job = try await store.executorJob(id: id, sessionID: conversationID)
    }
    var value = try MobileToolSupport.value(job).objectValue ?? [:]; value.removeValue(forKey: "code")
    if let result = job.result { value["execution"] = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(result.utf8)) }
    return .init(result: .object(value), requestID: request.requestID)
  }
}
