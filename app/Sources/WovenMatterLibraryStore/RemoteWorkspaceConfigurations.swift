import Foundation
import WovenMatterClient
import WovenMatterCore

extension WorkspaceDatabase {
  /// Publishes this Mac's remote workspace configurations. The registry
  /// refresh calls this every few seconds, so an unchanged configuration is
  /// never rewritten: it would otherwise become a new shared change each time.
  public func saveRemoteWorkspaceConfigurations(_ configurations: [RemoteWorkspaceConfiguration]) async throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try await write { connection in
      try connection.transaction {
        let owner = try connection.libraryIdentityUnlocked().hostDeviceID
        let ids = Set(configurations.map { $0.id.uuidString.lowercased() })
        var stored: [String: RemoteWorkspaceConfiguration] = [:]
        for row in try connection.historyRowsUnlocked("SELECT id,configuration FROM remote_workspace_configurations WHERE owner_device_id=? AND deleted=0", values: [owner]) {
          guard let id = row.objectValue?["id"]?.stringValue else { continue }
          if !ids.contains(id) {
            try connection.toolsExecuteUnlocked("UPDATE remote_workspace_configurations SET deleted=1 WHERE id=?", [id])
          } else if let json = row.objectValue?["configuration"]?.stringValue {
            stored[id] = try? JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: Data(json.utf8))
          }
        }
        for configuration in configurations {
          let id = configuration.id.uuidString.lowercased()
          if stored[id] == configuration { continue }
          let json = String(decoding: try encoder.encode(configuration), as: UTF8.self)
          try connection.toolsExecuteUnlocked("INSERT INTO remote_workspace_configurations VALUES(?,?,?,0) ON CONFLICT(id) DO UPDATE SET configuration=excluded.configuration,deleted=0 WHERE owner_device_id=excluded.owner_device_id", [id, owner, json])
        }
      }
    }
  }
}
