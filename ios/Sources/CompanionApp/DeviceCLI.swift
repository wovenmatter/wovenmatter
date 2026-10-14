import Foundation
import CryptoKit
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  static var deviceToolAccessOptions: [CompanionSelection] {
    WorkspaceToolGroup.allCases.map { .init(id: "wovenmatter_" + $0.rawValue, label: $0.title) }
  }
  static func deviceToolEnabled(_ name: String, selection: [String]?) -> Bool {
    let group: String
    if ["list_notes", "read_note", "save_note"].contains(name) { group = "wovenmatter_notes" }
    else if name.hasPrefix("wovenmatter_") { group = name }
    else { return true }
    guard let selection else { return group != "wovenmatter_computer" }
    // Retain access granted by older note-only selections, without broadening
    // those individual aliases into additional CLI capabilities.
    return selection.contains(group) || (group == "wovenmatter_notes" && selection.contains(name))
  }
  static var deviceCLITools: [[String: Any]] {
    WorkspaceToolGroup.allCases.map { group in
      let description = group.isAutomation
        ? "Control the paired central Mac's \(group == .browser ? "embedded Woven Matter browser" : "desktop after Computer Use is enabled"). This capability runs on the Mac, requires its execution access, and never controls this iPhone. Arguments omit the group name. Use [\"--help\"] for commands. Input uses a stable request ID; inspect fresh state after interruption."
        : "Run Woven Matter \(group.rawValue) commands using the same contract as the desktop CLI. Arguments omit the group name. Use [\"--help\"] for available commands. Local reads and edits work without the Mac. Set target=central to access the paired Mac when reachable. Mutations require approval and use a stable request ID."
      return ["name": "wovenmatter_" + group.rawValue,
       "description": description,
       "parameters": ["type": "object", "properties": ["arguments": ["type": "array", "items": ["type": "string"]], "target": ["type": "string", "enum": ["local", "central"]]], "required": ["arguments"]]]
    }
  }
  func deviceToolContext(conversationID: String) throws -> MobileToolContext {
    guard let record = executionRecords[conversationID] else { throw DeviceExecutionError.unavailable("This tool request has no device execution owner.") }
    let enabled = Set(WorkspaceToolGroup.allCases.filter { Self.deviceToolEnabled("wovenmatter_" + $0.rawValue, selection: record.enabledTools) })
    return .init(sessionID: conversationID, workspaceID: deviceWorkspaceID,
      folderID: state.conversations[conversationID]?.folderID, enabled: enabled, nativeToolIDs: Self.deviceToolDefinitions.compactMap { $0["name"] as? String }.filter { Self.deviceToolEnabled($0, selection: record.enabledTools) })
  }
  static func deviceCLIRequestID(_ string: String) -> String {
    if let uuid = UUID(uuidString: string) { return uuid.uuidString.lowercased() }
    let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
  }
  /// Called by both registered native tools and the embedded wovenmatter command.
  /// The caller identity comes from the executing runtime, never model arguments.
  func performDeviceCLI(arguments: [String], conversationID: String, requestID: String, target: String = "local") async throws -> String {
    var response: WovenMatterToolResponse
    do {
      guard let store else { throw DeviceExecutionError.unavailable("The device library is unavailable.") }
      let context = try deviceToolContext(conversationID: conversationID)
      var arguments = arguments
      var command = try WovenMatterToolCommand(arguments)
      try context.authorize(command)
      guard target == "local" || target == "central" else { throw WorkspaceToolError.invalid("Choose local or central.") }
      let target = command.group?.isAutomation == true ? "central" : target
      // --file is resolved solely against the caller's workspace before transport;
      // the central Mac never receives or reads an arbitrary device path.
      if let path = command.options["file"], let index = command.optionIndices["file"] {
        let url = try deviceWorkspaceURL(conversationID: conversationID, path: path)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= CompanionProtocol.maximumNoteBytes else { throw WorkspaceToolError.invalid("The command input file is too large.") }
        arguments[index] = command.group == .executor ? "--code" : command.action == "apply" ? "--json" : "--html"
        arguments[index + 1] = try String(contentsOf: url, encoding: .utf8)
        command = try WovenMatterToolCommand(arguments)
      }
      let id = Self.deviceCLIRequestID(command.options["request-id"] ?? requestID)
      let request = WovenMatterToolRequest(arguments: arguments, requestID: id)
      if command.isMutation, !command.wantsHelp, command.group?.isAutomation != true {
        if target == "local" { try await store.reserveToolInvocation(request, context: context) }
        try await requireDeviceApproval(id: conversationID + ":cli:" + id, conversationID: conversationID,
          title: "Woven Matter · " + command.commandPath,
          detail: (target == "central" ? "Central Mac\n" : "This device\n") + String(arguments.joined(separator: " ").prefix(2_000)))
      }
      if command.wantsHelp {
        response = .init(result: .object(["help": .string(WovenMatterToolCommand.help(for: command))]), requestID: id)
      } else if target == "central" {
        guard let transport else { throw MobileConnectionError.offline }
        try await publishDeviceToolCaller(conversationID)
        try Task.checkCancellation()
        let call = CompanionToolRequest(conversationID: conversationID, request: request, enabledGroups: context.enabled.sorted { $0.rawValue < $1.rawValue })
        let automationGroup = command.group?.isAutomation == true && command.action == "call" ? command.group : nil
        response = try await withTaskCancellationHandler {
          try await transport.executeTool(call)
        } onCancel: {
          guard let group = automationGroup else { return }
          // Accepted central work survives HTTP disconnection. Send scoped
          // cancellation even if the local task stopped before admission.
          let cancel = CompanionToolRequest(conversationID: conversationID,
            request: .init(arguments: [group.rawValue, "cancel", "--id", id]), enabledGroups: [])
          Task { _ = try? await transport.executeTool(cancel) }
        }
      } else if command.group == .calendar, !command.wantsHelp {
        try Task.checkCancellation()
        response = try await store.executeCalendarTool(command, request: request, context: context)
      } else if command.group == .sessions, command.isMutation, !command.wantsHelp {
        try Task.checkCancellation()
        response = try await executeDeviceSessionTool(command, request: request, conversationID: conversationID)
      } else if command.group == .executor, !command.wantsHelp {
        try Task.checkCancellation()
        response = try await executeDeviceExecutorTool(command, request: request, conversationID: conversationID)
      } else {
        await flushLocalWrites()
        try Task.checkCancellation()
        response = await store.executeLocalTool(request, context: context)
      }
      if target == "local", command.group == .library, command.action == "read", response.success {
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
    } catch { response = MobileToolSupport.response(error: error, requestID: Self.deviceCLIRequestID(requestID)) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(response.bounded()), as: UTF8.self)
  }
}
