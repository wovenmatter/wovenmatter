import Foundation
import WovenMatterCore

@MainActor
enum CompanionFederationAPI {
  static func handle(_ request: CompanionHTTPRequest, path: String, query: [URLQueryItem], device: CompanionPairedDevice,
                     database: WorkspaceDatabase, commands: any CompanionCommandServing) async throws -> CompanionHTTPResponse {
    func value(_ key: String) -> String? { query.first(where: { $0.name == key })?.value }
    let parts = path.split(separator: "/").map(String.init)
    if request.method == "GET" {
      switch path {
      case "/v1/federation/identity": return try .json(try await database.companionLibraryIdentity())
      case "/v1/federation/workspaces": return try .json(try await database.companionExecutionWorkspaces())
      case "/v1/federation/journal":
        guard let cursor = Int64(value("after") ?? "0"), cursor >= 0 else { return .error("invalid_cursor", "Invalid library journal cursor.", status: 400) }
        return try .json(try await database.companionJournal(after: cursor, limit: Int(value("limit") ?? "200") ?? 200))
      case "/v1/federation/artifacts": return try .json(try await database.companionSavedArtifacts())
      default: break
      }
      if parts.count == 4, parts[2] == "artifacts" {
        guard let transfer = try await database.companionArtifactTransfer(id: parts[3]) else { return .error("not_found", "Saved artifact not found.", status: 404) }
        return try .json(transfer)
      }
      if parts.count == 5, parts[2] == "artifacts", parts[4] == "chunk" {
        guard let offset = Int64(value("offset") ?? "0"), offset >= 0 else { return .error("invalid_offset", "Invalid artifact offset.", status: 400) }
        return try .json(try await database.companionArtifactChunk(id: parts[3], revision: value("revision").flatMap(Int64.init), offset: offset))
      }
      if parts.count == 6, parts[2] == "workspaces", parts[4] == "native-history" {
        guard let index = Int(value("part") ?? "0"), index >= 0 else { return .error("invalid_part", "Invalid native history part.", status: 400) }
        guard let part = try await database.companionNativeHistoryPart(workspaceID: parts[3], recordID: parts[5], partIndex: index) else {
          return .error("not_found", "This complete native history record is unavailable.", status: 404)
        }
        return try .json(part)
      }
    } else if request.method == "POST" {
      switch path {
      case "/v1/federation/workspaces":
        let registration = try JSONDecoder().decode(CompanionWorkspaceRegistration.self, from: request.body)
        // Root-host provisioning uses the internal store API. A remote request
        // always registers under its authenticated managing-device identity.
        guard registration.workspace.ownerDeviceID == device.id else {
          return .error("wrong_owner", "Only this workspace's managing device can register or change it.", status: 403)
        }
        return try .json(try await database.registerCompanionExecutionWorkspace(registration, deviceID: device.id))
      case "/v1/federation/journal":
        let batch = try JSONDecoder().decode(CompanionJournalBatch.self, from: request.body)
        return try .json(try await database.ingestCompanionJournal(batch, deviceID: device.id))
      case "/v1/federation/artifacts/register":
        let registration = try JSONDecoder().decode(CompanionArtifactRegistration.self, from: request.body)
        return try .json(try await database.registerCompanionArtifact(registration, deviceID: device.id))
      case "/v1/federation/artifacts/chunk":
        let chunk = try JSONDecoder().decode(CompanionArtifactChunk.self, from: request.body)
        return try .json(try await database.appendCompanionArtifactChunk(chunk, deviceID: device.id))
      case "/v1/federation/artifacts/commit":
        let commit = try JSONDecoder().decode(CompanionArtifactCommit.self, from: request.body)
        return try .json(try await database.commitCompanionArtifact(commit, deviceID: device.id))
      default: break
      }
      if parts.count == 5, parts[2] == "workspaces", parts[4] == "management" {
        let grant = try JSONDecoder().decode(CompanionExecutionManagementGrant.self, from: request.body)
        guard grant.workspaceID == parts[3], let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == grant.workspaceID }),
              !workspace.deleted, workspace.ownerDeviceID == device.id, workspace.endpoint == grant.endpoint,
              CompanionPairingPayload.isValidEndpoint(grant.endpoint), (32...256).contains(grant.token.utf8.count) else {
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
