import Foundation
import WovenMatterCore
import WovenMatterClient

// PR85 builds on PR86's asynchronous database boundary. Pure pages use the
// coherent read lane; coordination mutations and their receipts use one writer.
extension WorkspaceDatabase {
  public func queryCalendarRuns(eventID: String, after: Int = 0, limit: Int = 100) async throws -> GatewayJSONValue {
    try await read { try $0.queryCalendarRuns(eventID: eventID, after: after, limit: limit) }
  }

  public func querySessionTimers(callerID: String, sessionID: String, after: Int64 = 0,
                                 limit: Int = 100) async throws -> GatewayJSONValue {
    try await read { try $0.querySessionTimers(callerID: callerID, sessionID: sessionID, after: after, limit: limit) }
  }

  public func setAgentCoordinationNotifications(sourceID: String, targetID: String, epoch: String,
      enabled: Bool, requestID: String) async throws -> WorkspaceCoordinationMutationReceipt {
    try await write {
      try $0.setAgentCoordinationNotifications(sourceID: sourceID, targetID: targetID,
        epoch: epoch, enabled: enabled, requestID: requestID)
    }
  }

  public func releaseAgentCoordination(sourceID: String, targetID: String, epoch: String,
      requestID: String) async throws -> WorkspaceCoordinationMutationReceipt {
    try await write {
      try $0.releaseAgentCoordination(sourceID: sourceID, targetID: targetID,
        epoch: epoch, requestID: requestID)
    }
  }
}
