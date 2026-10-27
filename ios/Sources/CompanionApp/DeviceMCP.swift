import Foundation
import CryptoKit
import CompanionClient
import WovenMatterCompanion
import PiDurableRuntime

extension CompanionModel {
  static var deviceToolGroups: [WorkspaceToolGroup] { WorkspaceToolGroup.allCases }
  static func deviceToolSelectionID(_ group: WorkspaceToolGroup) -> String { "woven_" + group.rawValue }
  static var deviceToolAccessOptions: [CompanionSelection] {
    WorkspaceToolGroup.configurableCases.map { .init(id: deviceToolSelectionID($0), label: $0.title) }
  }

  /// Settings migration preserves the scope of saved selections without exposing
  /// the retired command interface or widening an individual note grant.
  static func migratedDeviceToolSelection(_ selection: [String]?) -> [String]? {
    MobileToolSupport.migratedMCPSelection(selection)
  }
  static func deviceToolEnabled(_ name: String, selection: [String]?) -> Bool {
    let definition = WovenMCPCatalog.tools.first { $0.name == name }
    let group = definition?.group ?? WorkspaceToolGroup.allCases.first { deviceToolSelectionID($0) == name }
    if group == .goals || group == .html { return true }
    guard let group else { return !name.hasPrefix("woven_") && !name.hasPrefix("wovenmatter_") && !["list_notes", "read_note", "save_note"].contains(name) }
    guard let selected = migratedDeviceToolSelection(selection) else { return group != .computer }
    if selected.contains(deviceToolSelectionID(group)) || selected.contains(name) { return true }
    // Group controls describe an existing partial grant without expanding it.
    return definition == nil && WovenMCPCatalog.tools.contains { $0.group == group && selected.contains($0.name) }
  }
  static var deviceMCPTools: [[String: Any]] {
    WovenMCPCatalog.tools.compactMap { definition in
      guard var schema = definition.inputSchema.objectValue else { return nil }
      var properties = schema["properties"]?.objectValue ?? [:]
      if definition.group?.isAutomation != true {
        properties["target"] = .object(["type": .string("string"), "enum": .array([.string("local"), .string("central")]),
          "description": .string("Default local. Choose central explicitly for the paired Mac. Goals belong to this device's execution owner.")])
      }
      schema["properties"] = .object(properties)
      guard let parameters = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayJSONValue.object(schema))) else { return nil }
      var result: [String: Any] = ["name": definition.name, "description": definition.description,
        "parameters": parameters]
      if !definition.isMutation, definition.annotations.objectValue?["idempotentHint"] != .bool(false) { result["replay"] = "safe" }
      return result
    }
  }
  func deviceToolContext(conversationID: String) throws -> MobileToolContext {
    guard let record = executionRecords[conversationID] else { throw DeviceExecutionError.unavailable("This tool request has no device execution owner.") }
    let enabled = Set(Self.deviceToolGroups.filter { Self.deviceToolEnabled(Self.deviceToolSelectionID($0), selection: record.enabledTools) })
    return .init(sessionID: conversationID, workspaceID: deviceWorkspaceID,
      folderID: state.conversations[conversationID]?.folderID, enabled: enabled,
      nativeToolIDs: Self.deviceToolDefinitions.compactMap { $0["name"] as? String }.filter { Self.deviceToolEnabled($0, selection: record.enabledTools) })
  }
  static func deviceMCPRequestID(_ string: String) -> String {
    if let uuid = UUID(uuidString: string) { return uuid.uuidString.lowercased() }
    let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
  }

  /// Native Pi and sandboxed Python use the canonical MCP schemas. Caller identity
  /// and request IDs are supplied by the executing runtime, never by a tool target.
  func performDeviceMCP(name: String, arguments: [String: GatewayJSONValue], conversationID: String,
                        requestID: String) async throws -> String {
    let id = Self.deviceMCPRequestID(requestID)
    let result: GatewayJSONValue
    var preparedPage: GatewayJSONValue?
    do {
      guard Self.deviceToolEnabled(name, selection: executionRecords[conversationID]?.enabledTools) else {
        throw DeviceExecutionError.unavailable("This tool is disabled for this conversation.")
      }
      var input = arguments
      let requestedTarget = input.removeValue(forKey: "target")?.stringValue ?? "local"
      guard ["local", "central"].contains(requestedTarget) else { throw WorkspaceToolError.invalid("Choose local or central.") }
      if input["requestID"] == nil { input["requestID"] = .string(id) }
      var metadata: [String: GatewayJSONValue] = [:]
      if ["woven_html_preview", "woven_html_render"].contains(name) {
        var source = input; source["action"] = .string(name == "woven_html_render" ? "render" : "preview")
        let raw = String(decoding: try JSONEncoder().encode(GatewayJSONValue.object(source)), as: UTF8.self)
        let prepared = try ConversationHTMLResources.prepareJSON(raw) { try self.deviceHTMLImageURL(conversationID: conversationID, path: $0) }
        let value = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(prepared.utf8))
        preparedPage = value
        input["html"] = value.objectValue?["html"]
        metadata["wovenHTMLMissingImages"] = value.objectValue?["missingImages"] ?? .array([])
      }
      let request = try WovenMCPCatalog.request(name: name, arguments: .object(input), contextID: executionRecords[conversationID]?.inputAssetID, metadata: .object(metadata))
      let command = try WovenMatterToolCommand(request.arguments)
      let context = try deviceToolContext(conversationID: conversationID)
      try context.authorize(command)
      if name == "woven_context", !context.enabled.contains(.notes) { throw WorkspaceToolError.disabled(.notes) }
      let target = command.group?.isAutomation == true ? "central" : requestedTarget
      if target == "central" {
        guard command.group != .goals else { throw WorkspaceToolError.invalid("Goals belong to this session’s execution owner. Use the local target.") }
        guard let transport else { throw MobileConnectionError.offline }
        if command.isMutation, command.group?.isAutomation != true {
          try await requireDeviceApproval(id: conversationID + ":mcp:" + request.requestID, conversationID: conversationID,
            title: "Woven Matter · " + name, detail: "Central Mac\n" + String(String(decoding: try JSONEncoder().encode(GatewayJSONValue.object(input)), as: UTF8.self).prefix(2_000)))
        }
        try await publishDeviceToolCaller(conversationID)
        try Task.checkCancellation()
        let message: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string("tools/call"),
          "params": .object(["name": .string(name), "arguments": .object(input), "_meta": .object(metadata)])])
        let automationGroup = command.group?.isAutomation == true && command.action == "call" ? command.group : nil
        let response = try await withTaskCancellationHandler {
          try await transport.executeMCP(message, conversationID: conversationID,
            enabledGroups: context.enabled.sorted { $0.rawValue < $1.rawValue }, contextID: nil)
        } onCancel: {
          guard let group = automationGroup, let cancelTool = group.automationCancelToolName else { return }
          let cancel: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString.lowercased()), "method": .string("tools/call"),
            "params": .object(["name": .string(cancelTool), "arguments": .object(["id": .string(request.requestID)])])])
          Task { _ = try? await transport.executeMCP(cancel, conversationID: conversationID, enabledGroups: [], contextID: nil) }
        }
        guard let value = response.objectValue?["result"] else {
          throw DeviceExecutionError.unavailable(response.objectValue?["error"]?.objectValue?["message"]?.stringValue ?? "The Mac returned an invalid MCP response.")
        }
        result = value
      } else {
        result = WovenMCPCatalog.result(await executeDeviceMCPOperation(request, conversationID: conversationID))
      }
    } catch { result = WovenMCPCatalog.result(MobileToolSupport.response(error: error, requestID: id)) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var output = result.objectValue ?? [:]
    if name == "woven_html_render", result.objectValue?["isError"] != .bool(true), let preparedPage {
      // Persist prepared bytes in native metadata, never in model-visible text.
      output["details"] = .object(["wovenHTMLPage": preparedPage])
    }
    return String(decoding: try encoder.encode(GatewayJSONValue.object(output)), as: UTF8.self)
  }

  private func executeDeviceMCPOperation(_ request: WovenMatterToolRequest, conversationID: String) async -> WovenMatterToolResponse {
    do {
      guard let store else { throw DeviceExecutionError.unavailable("The device library is unavailable.") }
      let context = try deviceToolContext(conversationID: conversationID)
      let command = try WovenMatterToolCommand(request.arguments)
      try context.authorize(command)
      if command.isMutation, command.group?.isAutomation != true {
        try await store.reserveToolInvocation(request, context: context)
        if command.group != .goals || ["set", "resume"].contains(command.action) {
          try await requireDeviceApproval(id: conversationID + ":mcp:" + request.requestID, conversationID: conversationID,
            title: "Woven Matter · " + command.commandPath, detail: "This device\n" + String(command.operationArguments.joined(separator: " ").prefix(2_000)))
        }
      }
      var response: WovenMatterToolResponse
      if command.group == .goals {
        let value: WorkspaceGoal?
        if command.action == "get" { value = executionRecords[conversationID]?.goalLedger?.goal }
        else { value = try await mutateDeviceGoal(conversationID, mutation: command.goalMutation(), requestID: request.requestID, agentInitiated: true) }
        response = .init(result: try MobileToolSupport.value(value), requestID: request.requestID)
      } else if command.group == .calendar {
        response = try await store.executeCalendarTool(command, request: request, context: context)
      } else if command.group == .sessions, command.isMutation {
        response = try await executeDeviceSessionTool(command, request: request, conversationID: conversationID)
      } else if command.group == .executor {
        response = try await executeDeviceExecutorTool(command, request: request, conversationID: conversationID)
      } else {
        await flushLocalWrites()
        try Task.checkCancellation()
        response = await store.executeLocalTool(request, context: context)
      }
      if command.group == .library, command.action == "read", response.success {
        let itemID = try command.required("id", allowPositional: true)
        if let source = await store.artifacts.localURL(id: itemID) {
          let manifest = await store.artifacts.manifests().first { $0.id == itemID }
          try Task.checkCancellation()
          let title = (manifest?.title ?? "artifact") as NSString
          let filename = title.lastPathComponent.isEmpty ? "artifact" : title.lastPathComponent
          let path = "library/" + UUID().uuidString.lowercased() + "/" + filename
          let destination = try deviceWorkspaceURL(conversationID: conversationID, path: path)
          try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: source, to: destination)
          var value = response.result?.objectValue ?? [:]; value["workspacePath"] = .string(path)
          response = .init(result: .object(value), requestID: response.requestID)
        }
      }
      await reload()
      return response
    } catch { return MobileToolSupport.response(error: error, requestID: request.requestID) }
  }

  /// On-device commands see their private virtual filesystem at /workspace.
  /// Translate that namespace without granting access to other app files.
  func deviceHTMLImageURL(conversationID: String, path: String) throws -> URL {
    guard path.hasPrefix("/workspace/") else {
      throw WorkspaceToolError.invalid("Device HTML images must use /workspace/... paths inside this conversation's workspace.")
    }
    return try deviceWorkspaceURL(conversationID: conversationID, path: String(path.dropFirst("/workspace/".count)))
  }
}

extension CompanionModel {
  @discardableResult
  func mutateDeviceGoal(_ id: String, mutation: WorkspaceGoalMutation, requestID: String? = nil,
                        agentInitiated: Bool = false, preparingInput: Bool = false) async throws -> WorkspaceGoal? {
    guard let record = executionRecords[id], record.isTrashed != true else { throw WorkspaceToolError.notFound("This session has no active device execution owner.") }
    let context = try deviceToolContext(conversationID: id)
    let starts: Bool
    switch mutation { case .set, .resume: starts = true; default: starts = false }
    guard !starts || !configuringDeviceSessions.contains(id) || agentInitiated || preparingInput else { throw WorkspaceToolError.invalid("Wait for this session’s configuration to finish.") }
    guard (!agentInitiated && !starts) || context.enabled.contains(.goals) else { throw WorkspaceToolError.invalid("Goals are disabled for this session.") }
    var ledger = record.goalLedger ?? .init()
    _ = try ledger.mutate(mutation, requestID: requestID, currentRunID: record.runID, sessionID: id)
    ledger.goal?.sessionID = id
    let stops: Bool
    switch mutation { case .pause, .clear, .edit: stops = !agentInitiated; default: stops = false }
    executionRecords[id]?.goalLedger = ledger
    do { try persistExecutionConfiguration() } catch { executionRecords[id] = record; throw error }
    if stops, record.runID != nil {
      // Fence continuation durably before cancelling this exact session.
      try await stopDeviceConversation(id)
    }
    return executionRecords[id]?.goalLedger?.goal
  }
  func deviceTokenUsage(_ runtime: PiDurableRuntime) async throws -> Int64? {
    try await runtime.tokenUsage()
  }

  func processDeviceGoals() async throws {
    guard let store else { return }
    let inbox = await store.toolSubmissions()
    for id in executionRecords.keys.sorted() {
      try Task.checkCancellation()
      guard let record = executionRecords[id], record.isTrashed != true, record.runID == nil,
            !["interrupted", "stopping", "failed"].contains(record.status), localRunTasks[id] == nil,
            !localStopping.contains(id), !localInterrupting.contains(id), !configuringDeviceSessions.contains(id),
            !(sending && selectedConversationID == id),
            !localPending.contains(where: { $0.conversationID == id }),
            !inbox.contains(where: { $0.sessionID == id && ["queued", "submitting", "accepted", "interrupted"].contains($0.state) }),
            (try? deviceToolContext(conversationID: id).enabled.contains(.goals)) == true else { continue }
      var ledger = record.goalLedger ?? .init()
      let requestID = UUID().uuidString.lowercased()
      guard let prompt = ledger.claimContinuation(id: requestID) else {
        if ledger != record.goalLedger { executionRecords[id]?.goalLedger = ledger; try persistExecutionConfiguration() }
        continue
      }
      executionRecords[id]?.goalLedger = ledger
      try persistExecutionConfiguration()
      do { _ = try await submitDevicePrompt(sessionID: id, requestID: requestID, text: prompt) }
      catch {
        // Unknown acceptance keeps the durable inbox; it is never replayed by a goal.
        if let goal = executionRecords[id]?.goalLedger?.goal, goal.status == .active {
          _ = try await mutateDeviceGoal(id, mutation: .block(id: goal.id, evidence: String(error.localizedDescription.prefix(1024))), agentInitiated: true)
        }
      }
    }
  }
}
