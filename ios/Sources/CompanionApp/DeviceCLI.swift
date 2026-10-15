import Foundation
import CryptoKit
import CompanionClient
import WovenMatterCompanion
import PiDurableRuntime

extension CompanionModel {
  static var deviceToolGroups: [WorkspaceToolGroup] { WorkspaceToolGroup.allCases }
  static var deviceToolAccessOptions: [CompanionSelection] {
    deviceToolGroups.filter { $0 != .goals }.map { .init(id: "wovenmatter_" + $0.rawValue, label: $0.title) }
  }
  static func deviceToolEnabled(_ name: String, selection: [String]?) -> Bool {
    if name == "wovenmatter_goals" { return true }
    let group: String
    if ["list_notes", "read_note", "save_note"].contains(name) { group = "wovenmatter_notes" }
    else if name.hasPrefix("wovenmatter_") { group = name }
    else { return true }
    guard let selection else { return true }
    // Retain access granted by older note-only selections, without broadening
    // those individual aliases into additional CLI capabilities.
    return selection.contains(group) || (group == "wovenmatter_notes" && selection.contains(name))
  }
  static var deviceCLITools: [[String: Any]] {
    deviceToolGroups.map { group in
      ["name": "wovenmatter_" + group.rawValue,
       "description": "Run Woven Matter \(group.rawValue) commands using the same contract as the desktop CLI. Arguments omit the group name. Use [\"--help\"] for available commands. Local reads and edits work without the Mac. Set target=central to access the paired Mac when reachable. Mutations require approval and use a stable request ID.",
       "parameters": ["type": "object", "properties": ["arguments": ["type": "array", "items": ["type": "string"]], "target": ["type": "string", "enum": ["local", "central"]]], "required": ["arguments"]]]
    }
  }
  func deviceToolContext(conversationID: String) throws -> MobileToolContext {
    guard let record = executionRecords[conversationID] else { throw DeviceExecutionError.unavailable("This tool request has no device execution owner.") }
    let selected = record.enabledTools.map(Set.init)
    let enabled = Set(Self.deviceToolGroups.filter { $0 == .goals || selected == nil || selected!.contains("wovenmatter_" + $0.rawValue) })
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
      if command.isMutation, !command.wantsHelp {
        if target == "local" { try await store.reserveToolInvocation(request, context: context) }
        if command.group != .goals || ["set", "resume"].contains(command.action) {
        try await requireDeviceApproval(id: conversationID + ":cli:" + id, conversationID: conversationID,
          title: "Woven Matter · " + command.commandPath,
          detail: (target == "central" ? "Central Mac\n" : "This device\n") + String(arguments.joined(separator: " ").prefix(2_000)))
        }
      }
      if target == "central", command.group == .goals { throw WorkspaceToolError.invalid("Goals belong to this session’s execution owner. Use the local target.") }
      if target == "central" {
        guard let transport else { throw MobileConnectionError.offline }
        try await publishDeviceToolCaller(conversationID)
        try Task.checkCancellation()
        response = try await transport.executeTool(.init(conversationID: conversationID, request: request, enabledGroups: context.enabled.sorted { $0.rawValue < $1.rawValue }))
      } else if command.group == .goals, !command.wantsHelp {
        let value: WorkspaceGoal?
        if command.action == "get" { value = executionRecords[conversationID]?.goalLedger?.goal }
        else { value = try await mutateDeviceGoal(conversationID, mutation: command.goalMutation(), requestID: id, agentInitiated: true) }
        response = .init(result: try MobileToolSupport.value(value), requestID: id)
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
