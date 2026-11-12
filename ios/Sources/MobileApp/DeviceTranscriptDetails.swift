import Foundation
import WovenMatterShared

extension MobileModel {
  /// Reading a durable native snapshot does not submit inference or resume work.
  /// Most expanded rows resolve entirely from the already persisted journal.
  func conversationActivityDetail(conversationID: String, runID: String, activityID: String) async throws -> AgentRunActivity? {
    func decode(_ activity: LibraryActivity?) -> AgentRunActivity? {
      activity?.projectionJSON?.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentRunActivity.self, from: $0) }
    }
    // A journaled record is complete; a compact row is complete only when it says so.
    let journaled = try await store?.journal.activityDetails(conversationID: conversationID, activityID: activityID)
    if let journaled, let activity = decode(journaled), journaled.detailsRecordID != nil || activity.detailsAvailable != true {
      return activity
    }
    if let record = executionRecords[conversationID] {
      let runtime = try await deviceRuntime(conversationID)
      let object = try Self.executionObject(await runtime.snapshot())
      let transcript = DeviceTranscript.project(snapshot: object, conversationID: conversationID,
        activeRunID: record.status == "running" ? record.runID : nil, runStatus: record.status)
      if let data = transcript.activities.first(where: { $0.id == activityID })?.projectionJSON?.data(using: .utf8) {
        return try JSONDecoder().decode(AgentRunActivity.self, from: data)
      }
    }
    // A Mac or Linux owner serves the full projection on its details route;
    // its streamed rows carry only the compact one.
    let remote: LibraryActivity?
    if let workspaceID = conversationWorkspaceIDs[conversationID], let client = workspaceClients[workspaceID] {
      if let detail = try? await client.activityDetails(conversationID, runID: runID, activityID: activityID) { remote = detail }
      else { remote = try await client.refreshTranscript(conversationID).activities.first { $0.id == activityID } }
    } else if let engine {
      remote = try await engine.transcriptActivityDetail(conversationID, runID: runID, activityID: activityID)
    } else { remote = nil }
    return decode(remote) ?? decode(journaled)
  }
}
