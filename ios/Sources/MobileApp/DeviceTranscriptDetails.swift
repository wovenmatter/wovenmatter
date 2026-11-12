import Foundation
import WovenMatterShared

extension MobileModel {
  /// One activity's complete projection, read once when its row is expanded,
  /// never streamed ahead or polled. Reading a durable native snapshot does not
  /// submit inference or resume work.
  func conversationActivityDetail(conversationID: String, runID: String, activityID: String) async throws -> AgentRunActivity? {
    func decode(_ activity: LibraryActivity?) -> AgentRunActivity? {
      activity?.projectionJSON?.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentRunActivity.self, from: $0) }
    }
    // A journaled record is complete; a compact row only when it says it has nothing more.
    let journaled = try? await store?.journal.activityDetails(conversationID: conversationID, activityID: activityID)
    if let journaled, let activity = decode(journaled), journaled.detailsRecordID != nil || activity.detailsAvailable != true {
      return activity
    }
    if let record = executionRecords[conversationID] {
      let runtime = try await deviceRuntime(conversationID)
      let object = try Self.executionObject(await runtime.snapshot())
      let transcript = DeviceTranscript.project(snapshot: object, conversationID: conversationID,
        activeRunID: record.status == "running" ? record.runID : nil, runStatus: record.status)
      if let activity = decode(transcript.activities.first { $0.id == activityID }) { return activity }
    }
    // The chat's owner serves the full projection on its details route
    // (`GET v1/execution/conversations/<id>/activity`, or the library host's
    // `GET v1/sessions/<id>/activity` for a central chat); its streamed rows
    // carry only the compact one. An owner too old for the route answers with
    // the activity as its transcript carries it.
    let remote: LibraryActivity?
    let route = executionRoute(for: conversationID)
    if route != "central", route != "local", let client = workspaceClients[route] {
      if let detail = try? await client.activityDetails(conversationID, runID: runID, activityID: activityID) { remote = detail }
      else { remote = try await client.refreshTranscript(conversationID).activities.first { $0.id == activityID } }
    } else if let engine {
      remote = try await engine.transcriptActivityDetail(conversationID, runID: runID, activityID: activityID)
    } else { remote = nil }
    return decode(remote) ?? decode(journaled)
  }
}
