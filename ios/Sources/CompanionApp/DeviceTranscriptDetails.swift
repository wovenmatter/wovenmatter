import Foundation
import WovenMatterCompanion

extension CompanionModel {
  /// Reading a durable native snapshot does not submit inference or resume work.
  /// Most expanded rows resolve entirely from the already persisted journal.
  func conversationActivityDetail(conversationID: String, activityID: String) async throws -> AgentRunActivity? {
    if let record = try await store?.journal.activityDetails(conversationID: conversationID, activityID: activityID),
       let data = record.projectionJSON?.data(using: .utf8),
       let activity = try? JSONDecoder().decode(AgentRunActivity.self, from: data) { return activity }
    if let record = executionRecords[conversationID] {
      let runtime = try await deviceRuntime(conversationID)
      let object = try Self.executionObject(await runtime.snapshot())
      let transcript = CompanionDeviceTranscript.project(snapshot: object, conversationID: conversationID,
        activeRunID: record.status == "running" ? record.runID : nil, runStatus: record.status)
      if let data = transcript.activities.first(where: { $0.id == activityID })?.projectionJSON?.data(using: .utf8) {
        return try JSONDecoder().decode(AgentRunActivity.self, from: data)
      }
    }
    let remote: CompanionActivity?
    if let workspaceID = conversationWorkspaceIDs[conversationID], let client = workspaceClients[workspaceID] {
      remote = try await client.refreshTranscript(conversationID).activities.first { $0.id == activityID }
    } else if let engine {
      remote = try await engine.transcriptActivityDetail(conversationID, activityID: activityID)
    } else { remote = nil }
    if let data = remote?.projectionJSON?.data(using: .utf8) {
      return try JSONDecoder().decode(AgentRunActivity.self, from: data)
    }
    return nil
  }
}
