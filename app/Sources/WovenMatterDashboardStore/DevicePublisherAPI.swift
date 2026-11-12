import Foundation
import WovenMatterCore

@MainActor
public enum DevicePublisherAPI {
  static func handle(_ request: LibraryHTTPRequest, path: String, database: WorkspaceDatabase) async throws -> LibraryHTTPResponse {
    guard request.method == "POST", let bearer = request.bearer else { return .error("unauthorized", "A workspace publisher is required.", status: 401) }
    let principal = try await database.authenticateLibraryWorkspacePublisher(bearer: bearer)
    guard request.headers["x-woven-workspace"] == principal.libraryID else { return .error("library_mismatch", "This publisher belongs to another library.", status: 409) }
    switch path {
    case "/v1/federation/publisher/association":
      struct Request: Decodable { var runID: String?; var nativeSessionID: String? }
      let value = try JSONDecoder().decode(Request.self, from: request.body)
      guard let runID = value.runID, (value.nativeSessionID?.utf8.count ?? 0) <= 4096,
            let association = try await database.libraryRetainedAssociation(workspaceID: principal.workspaceID, runID: runID, nativeSessionID: value.nativeSessionID) else {
        return .error("not_found", "No exact retained execution association exists in this workspace.", status: 404)
      }
      return try .json(association)
    case "/v1/federation/publisher/retained/settle":
      let batch = try JSONDecoder().decode(ExecutionJournalBatch.self, from: request.body)
      guard batch.libraryID == principal.libraryID, batch.entries.allSatisfy({ $0.workspaceID == principal.workspaceID }) else {
        return .error("wrong_owner", "A publisher may settle only exact retained runs from its workspace.", status: 403)
      }
      return try .json(try await database.settleLibraryRetainedRuns(batch, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/journal":
      let batch = try JSONDecoder().decode(ExecutionJournalBatch.self, from: request.body)
      guard batch.libraryID == principal.libraryID, batch.entries.allSatisfy({ $0.workspaceID == principal.workspaceID }) else {
        return .error("wrong_owner", "A publisher may submit only its own workspace history.", status: 403)
      }
      return try .json(try await database.ingestExecutionJournal(batch, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/register":
      let value = try JSONDecoder().decode(LibraryArtifactRegistration.self, from: request.body)
      guard value.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "A publisher may save only its own workspace artifacts.", status: 403) }
      return try .json(try await database.registerLibraryArtifact(value, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/chunk":
      let value = try JSONDecoder().decode(LibraryArtifactChunk.self, from: request.body)
      guard try await database.libraryArtifactTransfer(id: value.id)?.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "This artifact belongs to another workspace.", status: 403) }
      return try .json(try await database.appendLibraryArtifactChunk(value, deviceID: principal.executionDeviceID))
    case "/v1/federation/publisher/artifacts/commit":
      let value = try JSONDecoder().decode(LibraryArtifactCommit.self, from: request.body)
      guard try await database.libraryArtifactTransfer(id: value.id)?.manifest.workspaceID == principal.workspaceID else { return .error("wrong_owner", "This artifact belongs to another workspace.", status: 403) }
      return try .json(try await database.commitLibraryArtifact(value, deviceID: principal.executionDeviceID))
    default: return .error("not_found", "This publisher can submit workspace history and saved artifacts only.", status: 404)
    }
  }

  /// The same publisher bodies on a library host's local socket
  /// (`POST /v1/publisher/...`), for this machine's own Node server. The
  /// socket's bearer already proves the caller; the workspace named in the
  /// body must be a Linux execution workspace this library knows (its
  /// descriptor arrives with the adding Mac's records), and history is
  /// attributed to that workspace's execution device. A batch addressed to
  /// the adding Mac's library is written into this library copy, which then
  /// synchronizes everywhere; replies keep the caller's library ID.
  public static func handleLocal(_ request: LibraryHTTPRequest, path: String, database: WorkspaceDatabase) async throws -> LibraryHTTPResponse {
    guard request.method == "POST" else { return .error("method_not_allowed", "Use POST.", status: 405) }
    guard request.body.count <= FederationProtocol.maximumBatchBytes + 65_536 else { return .error("too_large", "Publish in smaller batches.", status: 413) }
    let own = try await database.libraryID()
    func workspace(_ id: String) async throws -> ExecutionWorkspace {
      guard let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id }), !workspace.deleted,
            workspace.kind == .linux, workspace.executionDeviceID != nil else {
        throw LibraryAPIError(code: "wrong_owner", message: "This machine's workspace is not registered in its library yet. Retry after it synchronizes with a Mac.")
      }
      return workspace
    }
    func batchWorkspace(_ batch: ExecutionJournalBatch) async throws -> ExecutionWorkspace? {
      let ids = Set(batch.entries.map(\.workspaceID))
      guard ids.count <= 1 else { throw LibraryAPIError(code: "wrong_owner", message: "Publish one workspace's history per batch.") }
      guard let id = ids.first else { return nil }
      let value = try await workspace(id)
      guard batch.libraryID == own || batch.libraryID == value.libraryID else {
        throw LibraryAPIError(code: "library_mismatch", message: "This history belongs to another library.")
      }
      return value
    }
    func relabel(_ result: ExecutionJournalBatchResult, _ libraryID: String) -> ExecutionJournalBatchResult {
      var copy = result; copy.libraryID = libraryID; return copy
    }
    switch path {
    case "/v1/publisher/association":
      // The workspace comes from the body or the `X-Woven-Workspace-ID` header.
      struct Request: Decodable { var workspaceID: String?; var runID: String?; var nativeSessionID: String? }
      let value = try JSONDecoder().decode(Request.self, from: request.body)
      guard let workspaceID = value.workspaceID ?? request.headers["x-woven-workspace-id"] else {
        return .error("invalid_request", "Name the workspace in X-Woven-Workspace-ID.", status: 400)
      }
      _ = try await workspace(workspaceID)
      guard let runID = value.runID, (value.nativeSessionID?.utf8.count ?? 0) <= 4096,
            let association = try await database.libraryRetainedAssociation(workspaceID: workspaceID, runID: runID, nativeSessionID: value.nativeSessionID) else {
        return .error("not_found", "No exact retained execution association exists in this workspace.", status: 404)
      }
      return try .json(association)
    case "/v1/publisher/retained/settle", "/v1/publisher/journal":
      var batch = try JSONDecoder().decode(ExecutionJournalBatch.self, from: request.body)
      let original = batch.libraryID
      guard let target = try await batchWorkspace(batch), let device = target.executionDeviceID else {
        return try .json(ExecutionJournalBatchResult(libraryID: original, acceptedEventIDs: [], cursor: 0))
      }
      batch.libraryID = own
      let result = path.hasSuffix("settle") ? try await database.settleLibraryRetainedRuns(batch, deviceID: device)
        : try await database.ingestExecutionJournal(batch, deviceID: device)
      return try .json(relabel(result, original))
    case "/v1/publisher/artifacts/register":
      let value = try JSONDecoder().decode(LibraryArtifactRegistration.self, from: request.body)
      let target = try await workspace(value.manifest.workspaceID)
      return try .json(try await database.registerLibraryArtifact(value, deviceID: target.executionDeviceID ?? ""))
    case "/v1/publisher/artifacts/chunk":
      let value = try JSONDecoder().decode(LibraryArtifactChunk.self, from: request.body)
      guard let id = try await database.libraryArtifactTransfer(id: value.id)?.manifest.workspaceID else { return .error("not_found", "Register this artifact first.", status: 404) }
      return try .json(try await database.appendLibraryArtifactChunk(value, deviceID: try await workspace(id).executionDeviceID ?? ""))
    case "/v1/publisher/artifacts/commit":
      let value = try JSONDecoder().decode(LibraryArtifactCommit.self, from: request.body)
      guard let id = try await database.libraryArtifactTransfer(id: value.id)?.manifest.workspaceID else { return .error("not_found", "Register this artifact first.", status: 404) }
      return try .json(try await database.commitLibraryArtifact(value, deviceID: try await workspace(id).executionDeviceID ?? ""))
    default: return .error("not_found", "This publisher can submit workspace history and saved artifacts only.", status: 404)
    }
  }
}
