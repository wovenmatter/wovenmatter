import Foundation
import CompanionClient
import CompanionInference
import WovenMatterCompanion

extension CompanionModel {
  static var deviceToolDefinitions: [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(deviceToolsJSON.utf8))) as? [[String: Any]] ?? [] }
  func toolsJSON(for record: DeviceConversationRecord) throws -> String {
    guard let enabled = record.enabledTools else { return Self.deviceToolsJSON }
    return try Self.toolJSON(Self.deviceToolDefinitions.filter { ($0["name"] as? String).map { enabled.contains($0) } == true })
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
      let tools: [CompanionSelection] = Self.deviceToolDefinitions.compactMap { definition in
        guard let name = definition["name"] as? String else { return nil }
        return .init(id: name, label: name.replacingOccurrences(of: "_", with: " ").capitalized)
      }
      return .session(.init(conversationID: id, model: record.connectionID, thinking: nil, permission: nil,
        models: inferenceConnections.map { .init(id: $0.id, label: $0.name + " · " + $0.modelID) }, thinkingLevels: [], permissions: [],
        availableTools: tools, enabledTools: record.enabledTools ?? tools.map(\.id), canConfigure: !sending && localRunTokens[id] == nil && record.status != "running" && record.status != "stopping" && record.status != "interrupted"))
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
      case .configureSession(let id, let connectionID, _, _):
        guard var record = executionRecords[id], !sending, localRunTokens[id] == nil, record.status != "running", record.status != "stopping", record.status != "interrupted" else { throw DeviceExecutionError.unavailable("Finish or stop the saved run before changing its model.") }
        if let connectionID {
          guard let connection = inferenceConnections.first(where: { $0.id == connectionID }) else { throw InferenceError.invalidConfiguration }
          let model = try await CompanionInferenceService(connection: connection, credentials: executionCredentialStore).model()
          record.connectionID = connection.id; record.connection = connection; record.modelJSON = try model.descriptorJSON()
          try await localRuntimes[id]?.close(); localRuntimes.removeValue(forKey: id)
          executionRecords[id] = record; try persistExecutionConfiguration()
          let runtime = try await deviceRuntime(id); try await runtime.configure(modelJSON: record.modelJSON)
        }
      case .sessionTools(let id, let enabled, _):
        guard var record = executionRecords[id], !sending, localRunTokens[id] == nil, record.status != "running", record.status != "stopping", record.status != "interrupted" else { throw DeviceExecutionError.unavailable("Finish or stop the saved run before changing tool access.") }
        let available = Set(Self.deviceToolDefinitions.compactMap { $0["name"] as? String })
        guard Set(enabled).isSubset(of: available) else { throw DeviceExecutionError.unavailable("An unknown device tool was selected.") }
        try await localRuntimes[id]?.close(); localRuntimes.removeValue(forKey: id)
        record.enabledTools = enabled; executionRecords[id] = record; try persistExecutionConfiguration()
      default: throw DeviceExecutionError.unavailable("This action belongs to the central library.")
      }
      return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
}
