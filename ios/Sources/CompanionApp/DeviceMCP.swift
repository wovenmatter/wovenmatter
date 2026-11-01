import Foundation
import CryptoKit
import CompanionClient
import WovenMatterCompanion
import PiDurableRuntime

extension CompanionModel {
  static var deviceToolGroups: [WorkspaceToolGroup] { [.notes] }
  static func deviceToolSelectionID(_ group: WorkspaceToolGroup) -> String { "woven_" + group.rawValue }
  static var deviceToolAccessOptions: [CompanionSelection] { QuickChatCapabilities.options }
  static func migratedDeviceToolSelection(_ selection: [String]?) -> [String]? { MobileToolSupport.migratedMCPSelection(selection) }
  static func deviceToolEnabled(_ name: String, selection: [String]?) -> Bool { QuickChatCapabilities.enabled(name, selection: selection) }
  static var deviceMCPTools: [[String: Any]] {
    WovenMCPCatalog.tools.filter { QuickChatCapabilities.toolNames.contains($0.name) }.compactMap { definition in
      guard let parameters = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(definition.inputSchema)) else { return nil }
      var tool: [String: Any] = ["name": definition.name, "description": definition.description, "parameters": parameters]
      if !definition.isMutation { tool["replay"] = "safe" }
      return tool
    }
  }
  func deviceToolContext(conversationID: String) throws -> MobileToolContext {
    guard let record = executionRecords[conversationID], record.quickChatVersion == 1 else {
      throw DeviceExecutionError.unavailable("This tool request has no Quick Chat owner.")
    }
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
  /// The same fixed allowlist is enforced here and at the native tool entry point.
  /// Quick Chat can mutate its notes replica, never invoke host MCP automation.
  func performDeviceMCP(name: String, arguments: [String: GatewayJSONValue], conversationID: String, requestID: String) async throws -> String {
    let id = Self.deviceMCPRequestID(requestID)
    let response: WovenMatterToolResponse
    do {
      guard let store else { throw MobileConnectionError.offline }
      guard Self.deviceToolEnabled(name, selection: executionRecords[conversationID]?.enabledTools) else {
        throw DeviceExecutionError.unavailable("This tool is disabled for this conversation.")
      }
      var input = arguments
      guard (input.removeValue(forKey: "target")?.stringValue ?? "local") == "local" else {
        throw DeviceExecutionError.unavailable("Choose a Mac or Linux workspace agent for host operations.")
      }
      input["requestID"] = .string(id)
      let context = try deviceToolContext(conversationID: conversationID)
      let request = try WovenMCPCatalog.request(name: name, arguments: .object(input), contextID: executionRecords[conversationID]?.inputAssetID)
      let command = try WovenMatterToolCommand(request.arguments)
      try context.authorize(command)
      if name == "woven_context", !context.enabled.contains(.notes) { throw WorkspaceToolError.disabled(.notes) }
      await flushLocalWrites()
      if command.isMutation {
        try await store.reserveToolInvocation(request, context: context)
        try await requireDeviceApproval(id: conversationID + ":mcp:" + id, conversationID: conversationID,
          title: "Quick Chat · " + name, detail: String(command.operationArguments.joined(separator: " ").prefix(2_000)))
      }
      try Task.checkCancellation()
      response = await store.executeLocalTool(request, context: context)
      await reload()
    } catch { response = MobileToolSupport.response(error: error, requestID: id) }
    return String(decoding: try JSONEncoder().encode(WovenMCPCatalog.result(response)), as: UTF8.self)
  }
  func deviceTokenUsage(_ runtime: PiDurableRuntime) async throws -> Int64? { try await runtime.tokenUsage() }
}
