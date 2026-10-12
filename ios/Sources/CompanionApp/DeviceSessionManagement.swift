import Foundation
import CompanionClient
import CompanionInference
import WovenMatterCompanion

extension CompanionModel {
  static var deviceToolDefinitions: [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(deviceToolsJSON.utf8))) as? [[String: Any]] ?? [] }
  func toolsJSON(for record: DeviceConversationRecord) throws -> String {
    return try Self.toolJSON(Self.deviceToolDefinitions.filter { ($0["name"] as? String).map { Self.deviceToolEnabled($0, selection: record.enabledTools) } == true })
  }
  func restoreDeviceConversation(_ id: String) async {
    guard var record = executionRecords[id], record.isTrashed == true else { return }
    do {
      record.isTrashed = false; record.updatedAt = Self.executionTimestamp()
      let conversation = CompanionConversation(id: id, title: record.title, folderID: record.folderID, providerID: "pi-durable-device",
        routeID: deviceWorkspaceID, runtimeKind: "pi", updatedAt: record.updatedAt, isPinned: record.isPinned)
      try await store?.journal.restoreConversation(workspaceID: deviceWorkspaceID, conversation: conversation)
      executionRecords[id] = record; try persistExecutionConfiguration()
      try await store?.restoreExecutionProjection(); await reload()
    } catch { errorMessage = error.localizedDescription }
  }
  func readDeviceWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
    switch request {
    case .session(let id):
      guard let record = executionRecords[id] else { throw DeviceExecutionError.unavailable("This device conversation is unavailable.") }
      let tools = Self.deviceToolAccessOptions
      return .session(.init(conversationID: id, model: record.connectionID, thinking: record.thinkingLevel ?? "off", permission: nil,
        models: inferenceConnections.map { .init(id: $0.id, label: $0.name + " · " + $0.modelID) }, thinkingLevels: ((try? JSONDecoder().decode(InferenceModel.self, from: Data(record.modelJSON.utf8)))?.supportedThinkingLevels ?? []).map { .init(id: $0, label: $0.capitalized) }, permissions: [],
        availableTools: tools, enabledTools: tools.filter { Self.deviceToolEnabled($0.id, selection: record.enabledTools) }.map(\.id), canConfigure: !sending && localRunTokens[id] == nil && record.status != "running" && record.status != "stopping" && record.status != "interrupted"))
    case .exportConversation(let id, let format):
      guard executionRecords[id] != nil else { throw DeviceExecutionError.unavailable("This device conversation is unavailable.") }
      if format == "fullRun" {
        await exportDeviceNativeHistory(id)
        let entries = await store?.journal.snapshot().entries.values.filter { $0.conversationID == id }.sorted { $0.originSequence < $1.originSequence } ?? []
        return .file(.init(name: "conversation-\(id).json", mimeType: "application/json", data: try JSONEncoder().encode(entries)))
      }
      let journal = await store?.journal.snapshot()
      let transcript = journal?.transcripts[id] ?? state.transcripts[id]
      let text = (transcript?.messages ?? []).map { "## \($0.role.capitalized)\n\n\($0.content)" }.joined(separator: "\n\n")
      return .file(.init(name: "conversation-\(id).md", mimeType: "text/markdown", data: Data(text.utf8)))
    default: throw DeviceExecutionError.unavailable("This action belongs to the central library.")
    }
  }
  func performDeviceAction(_ action: CompanionWorkspaceAction) async -> Bool {
    do {
      switch action {
      case .conversation(let id, let operation, let title, let folderID):
        guard var record = executionRecords[id] else { throw DeviceExecutionError.unavailable("This device conversation is unavailable.") }
        switch operation {
        case "rename":
          guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeviceExecutionError.unavailable("Enter a conversation title.") }
          record.title = title
        case "move": record.folderID = folderID
        case "pin": record.isPinned = true
        case "unpin": record.isPinned = false
        case "trash":
          guard !sending, localRunTokens[id] == nil, record.status != "running", record.status != "stopping", record.status != "interrupted" else { throw DeviceExecutionError.unavailable("Stop this run before moving its conversation to Trash.") }
          record.isTrashed = true
          executionRecords[id] = record; try persistExecutionConfiguration()
          try await store?.journal.deleteConversation(workspaceID: deviceWorkspaceID, conversationID: id)
          try await localRuntimes[id]?.close(); localRuntimes.removeValue(forKey: id)
          try await store?.restoreExecutionProjection(); await reload()
          if selectedConversationID == id { selectedConversationID = nil }
          return true
        default: throw DeviceExecutionError.unavailable("This conversation action is not supported on this device.")
        }
        record.updatedAt = Self.executionTimestamp(); executionRecords[id] = record
        try persistExecutionConfiguration(); try await adoptDeviceConversation(record, transcript: nil); await reload()
      case .configureSession(let id, let connectionID, let thinking, _):
        guard let record = executionRecords[id] else { throw InferenceError.invalidConfiguration }
        let connection: InferenceConnection?
        if let connectionID {
          connection = connectionID == record.connectionID ? record.connection ?? inferenceConnections.first { $0.id == connectionID } : inferenceConnections.first { $0.id == connectionID }
          guard connection != nil else { throw InferenceError.invalidConfiguration }
        } else { connection = nil }
        try await configureDeviceChat(connection: connection, thinking: thinking, conversationID: id)
      case .sessionTools(let id, let enabled, _):
        try await configureDeviceChat(tools: enabled, conversationID: id)
      default: throw DeviceExecutionError.unavailable("This action belongs to the central library.")
      }
      return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
}
