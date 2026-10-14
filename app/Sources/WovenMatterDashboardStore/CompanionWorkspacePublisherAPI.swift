import Foundation
import WovenMatterCore

@MainActor
enum CompanionWorkspacePublisherAPI {
  static func handle(_ request: CompanionHTTPRequest, path: String, database: WorkspaceDatabase) async throws -> CompanionHTTPResponse {
    guard request.method == "POST", let bearer = request.bearer else { return .error("unauthorized", "A workspace publisher is required.", status: 401) }
    let principal = try await database.authenticateCompanionWorkspacePublisher(bearer: bearer)
    guard request.headers["x-woven-workspace"] == principal.libraryID else { return .error("library_mismatch", "This publisher belongs to another library.", status: 409) }
    switch path {
    case "/v1/federation/publisher/association":
      struct Request: Decodable { var runID: String?; var nativeSessionID: String? }
      let value = try JSONDecoder().decode(Request.self, from: request.body)
      guard let runID = value.runID, (value.nativeSessionID?.utf8.count ?? 0) <= 4096,
            let association = try await database.companionRetainedAssociation(workspaceID: principal.workspaceID, runID: runID, nativeSessionID: value.nativeSessionID) else {
        return .error("not_found", "No exact retained execution association exists in this workspace.", status: 404)
      }
      return try .json(association)
    case "/v1/federation/publisher/retained/settle":
      let batch = try JSONDecoder().decode(CompanionJournalBatch.self, from: request.body)
      guard batch.libraryID == principal.libraryID, batch.entries.allSatisfy({ $0.workspaceID == principal.workspaceID }) else {
        return .error("wrong_owner", "A publisher may settle only exact retained runs from its workspace.", status: 403)
      }
      return try .json(try await database.settleCompanionRetainedRuns(batch, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/journal":
      let batch = try JSONDecoder().decode(CompanionJournalBatch.self, from: request.body)
      guard batch.libraryID == principal.libraryID, batch.entries.allSatisfy({ $0.workspaceID == principal.workspaceID }) else {
        return .error("wrong_owner", "A publisher may submit only its own workspace history.", status: 403)
      }
      return try .json(try await database.ingestCompanionJournal(batch, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/register":
      let value = try JSONDecoder().decode(CompanionArtifactRegistration.self, from: request.body)
      guard value.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "A publisher may save only its own workspace artifacts.", status: 403) }
      return try .json(try await database.registerCompanionArtifact(value, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/chunk":
      let value = try JSONDecoder().decode(CompanionArtifactChunk.self, from: request.body)
      guard try await database.companionArtifactTransfer(id: value.id)?.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "This artifact belongs to another workspace.", status: 403) }
      return try .json(try await database.appendCompanionArtifactChunk(value, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/commit":
      let value = try JSONDecoder().decode(CompanionArtifactCommit.self, from: request.body)
      guard try await database.companionArtifactTransfer(id: value.id)?.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "This artifact belongs to another workspace.", status: 403) }
      return try .json(try await database.commitCompanionArtifact(value, deviceID: principal.executionDeviceID))
    default: return .error("not_found", "This publisher can submit workspace history and saved artifacts only.", status: 404)
    }
  }
}
