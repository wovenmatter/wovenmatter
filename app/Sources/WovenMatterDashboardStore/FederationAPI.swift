import Foundation
import WovenMatterCore

@MainActor
enum FederationAPI {
  static func handle(_ request: LibraryHTTPRequest, path: String, query: [URLQueryItem], device: PairedDevice,
                     database: WorkspaceDatabase, commands: any DeviceCommandServing) async throws -> LibraryHTTPResponse {
    func value(_ key: String) -> String? { query.first(where: { $0.name == key })?.value }
    let parts = path.split(separator: "/").map(String.init)
    func ownsClientWorkspace(_ id: String) async throws -> Bool {
      guard let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id }) else { return false }
      return !workspace.deleted && workspace.kind != .linux && workspace.ownerDeviceID == device.id
        && (workspace.executionDeviceID == nil || workspace.executionDeviceID == device.id)
    }
    func rejectedRelay() -> LibraryHTTPResponse {
      .error("wrong_owner", "This client may publish only its own on-device history and saved assets.", status: 403)
    }
    if request.method == "GET" {
      switch path {
      case "/v1/federation/identity": return try .json(try await database.libraryIdentity())
      case "/v1/federation/workspaces": return try .json(try await database.libraryExecutionWorkspaces())
      case "/v1/federation/journal":
        guard let cursor = Int64(value("after") ?? "0"), cursor >= 0 else { return .error("invalid_cursor", "Invalid library journal cursor.", status: 400) }
        return try .json(try await database.executionJournal(after: cursor, limit: Int(value("limit") ?? "200") ?? 200))
      case "/v1/federation/artifacts": return try .json(try await database.librarySavedArtifacts())
      default: break
      }
      if parts.count == 4, parts[2] == "artifacts" {
        guard let transfer = try await database.libraryArtifactTransfer(id: parts[3]) else { return .error("not_found", "Saved artifact not found.", status: 404) }
        return try .json(transfer)
      }
      if parts.count == 5, parts[2] == "artifacts", parts[4] == "chunk" {
        guard let offset = Int64(value("offset") ?? "0"), offset >= 0 else { return .error("invalid_offset", "Invalid artifact offset.", status: 400) }
        return try .json(try await database.libraryArtifactChunk(id: parts[3], revision: value("revision").flatMap(Int64.init), offset: offset))
      }
      if parts.count == 6, parts[2] == "workspaces", parts[4] == "native-history" {
        guard let index = Int(value("part") ?? "0"), index >= 0 else { return .error("invalid_part", "Invalid native history part.", status: 400) }
        guard let part = try await database.libraryNativeHistoryPart(workspaceID: parts[3], recordID: parts[5], partIndex: index) else {
          return .error("not_found", "This complete native history record is unavailable.", status: 404)
        }
        return try .json(part)
      }
    } else if request.method == "POST" {
      switch path {
      case "/v1/federation/workspaces":
        let registration = try JSONDecoder().decode(LibraryWorkspaceRegistration.self, from: request.body)
        // Root-host provisioning uses the internal store API. A remote request
        // always registers under its authenticated managing-device identity.
        guard registration.workspace.ownerDeviceID == device.id else {
          return .error("wrong_owner", "Only this workspace's managing device can register or change it.", status: 403)
        }
        return try .json(try await database.registerExecutionWorkspace(registration, deviceID: device.id))
      case "/v1/federation/journal":
        let batch = try JSONDecoder().decode(ExecutionJournalBatch.self, from: request.body)
        for workspaceID in Set(batch.entries.map(\.workspaceID)) {
          guard try await ownsClientWorkspace(workspaceID) else { return rejectedRelay() }
        }
        return try .json(try await database.ingestExecutionJournal(batch, deviceID: device.id))
      case "/v1/federation/artifacts/register":
        let registration = try JSONDecoder().decode(LibraryArtifactRegistration.self, from: request.body)
        guard try await ownsClientWorkspace(registration.manifest.workspaceID) else { return rejectedRelay() }
        return try .json(try await database.registerLibraryArtifact(registration, deviceID: device.id))
      case "/v1/federation/artifacts/chunk":
        let chunk = try JSONDecoder().decode(LibraryArtifactChunk.self, from: request.body)
        guard let workspaceID = try await database.libraryArtifactTransfer(id: chunk.id)?.manifest.workspaceID,
              try await ownsClientWorkspace(workspaceID) else { return rejectedRelay() }
        return try .json(try await database.appendLibraryArtifactChunk(chunk, deviceID: device.id))
      case "/v1/federation/artifacts/commit":
        let commit = try JSONDecoder().decode(LibraryArtifactCommit.self, from: request.body)
        guard let workspaceID = try await database.libraryArtifactTransfer(id: commit.id)?.manifest.workspaceID,
              try await ownsClientWorkspace(workspaceID) else { return rejectedRelay() }
        return try .json(try await database.commitLibraryArtifact(commit, deviceID: device.id))
      default: break
      }
      if parts.count == 5, parts[2] == "workspaces", parts[4] == "management" {
        let grant = try JSONDecoder().decode(ExecutionManagementGrant.self, from: request.body)
        guard grant.workspaceID == parts[3], let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == grant.workspaceID }),
              !workspace.deleted, workspace.ownerDeviceID == device.id, workspace.endpoint == grant.endpoint,
              PairingPayload.isValidEndpoint(grant.endpoint), (32...256).contains(grant.token.utf8.count) else {
          return .error("wrong_owner", "Only the registered workspace owner can grant management at its verified endpoint.", status: 403)
        }
        return try .json(try await commands.registerExecutionManagement(grant, device: device))
      }
      if parts.count == 5, parts[2] == "workspaces", parts[4] == "credential" {
        return try .json(try await commands.provisionExecutionWorkspace(id: parts[3], device: device))
      }
    }
    return .error("not_found", "Unknown library federation endpoint.", status: 404)
  }
}
