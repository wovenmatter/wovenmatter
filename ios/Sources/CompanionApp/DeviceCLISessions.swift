import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  func executeDeviceSessionTool(_ c: WovenMatterToolCommand, request: WovenMatterToolRequest, conversationID: String) async throws -> WovenMatterToolResponse {
    try Task.checkCancellation()
    guard let store, let source = executionRecords[conversationID], source.isTrashed != true else { throw WorkspaceToolError.notFound("The caller does not execute on this iPhone.") }
    let localIDs = Set(executionRecords.values.filter { $0.isTrashed != true }.map(\.id))
    let id = c.action == "create" ? request.requestID : try c.required("id", allowPositional: true)
    if c.action == "create" {
      if let workspace = c.options["workspace"], !["local", deviceWorkspaceID].contains(workspace) { throw WorkspaceToolError.invalid("This command creates sessions on this iPhone only.") }
      if let runtime = c.options["harness"], !["pi", "pi-durable", "default_agent"].contains(runtime) { throw WorkspaceToolError.invalid("This device provides Pi Durable.") }
      if c.options["directory"] != nil { throw WorkspaceToolError.invalid("Use files in the device workspace; external host paths do not apply.") }
      let text = try c.required("text"), title = try c.required("title"), purpose = try c.required("purpose")
      if let receipt = await store.toolSubmission(requestID: request.requestID), receipt.sessionID != id || receipt.text != text { throw WorkspaceToolError.invalid("The request ID is already used for different session content.") }
      // Destination defaults remain user controlled. An agent cannot expand its
      // authority by creating a child with broader tools than its own selection.
      let defaults = deviceAgentDefaults.enabledTools ?? Self.deviceToolDefinitions.compactMap { $0["name"] as? String }.filter { Self.deviceToolEnabled($0, selection: nil) }
      let permitted = defaults.filter { Self.deviceToolEnabled($0, selection: source.enabledTools) }.sorted()
      try await createDeviceToolSession(id: id, title: title, folderID: c.options["folder"] ?? source.folderID,
        model: c.options["model"], thinking: c.options["thinking"], enabledTools: permitted)
      if c.options["independent"] == nil {
        _ = try await store.coordinateLocalSessions(callerID: conversationID, targetID: id, localExecutionIDs: localIDs.union([id]), purpose: purpose, notifications: true, requestID: request.requestID)
      }
      let submission = try await submitDevicePrompt(sessionID: id, requestID: request.requestID, text: text)
      return .init(result: .object(["id": .string(id), "state": .string(submission.state), "requestID": .string(submission.id)]), requestID: request.requestID)
    }
    guard localIDs.contains(id) else { throw WorkspaceToolError.notFound("The target session does not execute on this iPhone.") }
    switch c.action {
    case "send":
      let submission = try await submitDevicePrompt(sessionID: id, requestID: request.requestID, text: c.required("text"))
      return .init(result: try MobileToolSupport.value(submission), requestID: request.requestID)
    case "manage":
      let relation = try await store.coordinateLocalSessions(callerID: conversationID, targetID: id, localExecutionIDs: localIDs,
        purpose: c.required("purpose"), notifications: c.options["no-notify"] == nil, requestID: request.requestID)
      return .init(result: try MobileToolSupport.value(relation), requestID: request.requestID)
    case "release", "notifications":
      var enabled: Bool?
      if c.action == "notifications" {
        let value = try c.required("enabled")
        guard ["true", "false"].contains(value) else { throw WorkspaceToolError.invalid("Use --enabled true or false.") }; enabled = value == "true"
      }
      return .init(result: try await store.changeLocalSessionCoordination(callerID: conversationID, targetID: id,
        localExecutionIDs: localIDs, epoch: c.required("epoch"), enabled: enabled, requestID: request.requestID), requestID: request.requestID)
    default: throw WorkspaceToolError.invalid("Unsupported local session operation.")
    }
  }
}
