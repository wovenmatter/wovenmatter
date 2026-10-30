import Foundation
import WovenMatterClient
import WovenMatterCore

public struct PairedRemoteWorkspace: Codable, Sendable {
  public let id: String
  public let ownerDeviceID: String
  public let configuration: String
  public let deleted: Bool
}
extension WorkspaceDatabase {
  public func savePairedRemoteWorkspaces(_ configurations: [RemoteWorkspaceConfiguration]) async throws {
    try await write { connection in
      try connection.transaction {
        let owner = try connection.companionLibraryIdentityUnlocked().hostDeviceID
        let ids = Set(configurations.map { $0.id.uuidString.lowercased() })
        for row in try connection.historyRowsUnlocked("SELECT id FROM paired_remote_workspaces WHERE owner_device_id=? AND deleted=0", values: [owner]) {
          if let id = row.objectValue?["id"]?.stringValue, !ids.contains(id) {
            try connection.toolsExecuteUnlocked("UPDATE paired_remote_workspaces SET deleted=1 WHERE id=?", [id])
          }
        }
        for configuration in configurations {
          let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
          try connection.toolsExecuteUnlocked("INSERT INTO paired_remote_workspaces VALUES(?,?,?,0) ON CONFLICT(id) DO UPDATE SET configuration=excluded.configuration,deleted=0 WHERE owner_device_id=excluded.owner_device_id", [configuration.id.uuidString.lowercased(), owner, json])
        }
      }
    }
  }
  public func pairedRemoteWorkspaces() async throws -> [PairedRemoteWorkspace] {
    try await read { connection in
      try connection.historyRowsUnlocked("SELECT * FROM paired_remote_workspaces ORDER BY id", values: []).map {
        let row = $0.objectValue!
        return .init(id: row["id"]!.stringValue!, ownerDeviceID: row["owner_device_id"]!.stringValue!, configuration: row["configuration"]!.stringValue!, deleted: row["deleted"]?.doubleValue == 1)
      }
    }
  }
}
