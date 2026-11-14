import Foundation
import WovenMatterShared

public struct MobileLocalSessionCoordination: Codable, Equatable, Sendable {
  public var coordinatorID: String
  public var targetID: String
  public var epoch: String
  public var purpose: String
  public var notifications: Bool
}

extension MobileStore {
  /// This local table never routes commands to another device. The native caller
  /// supplies IDs from its private executionRecords, not the synchronized index.
  public func coordinateLocalSessions(callerID: String, targetID: String, localExecutionIDs: Set<String>, purpose: String,
    notifications: Bool, requestID: String) throws -> MobileLocalSessionCoordination {
    try Task.checkCancellation()
    guard localExecutionIDs.contains(callerID), localExecutionIDs.contains(targetID) else { throw WorkspaceToolError.invalid("Both sessions must execute on this device.") }
    let key = callerID + ":" + requestID, arguments = ["manage", targetID, purpose, String(notifications)]
    if let receipt = state.toolReceipts?[key] {
      guard receipt.arguments == arguments, let result = receipt.response.result else { throw WorkspaceToolError.invalid("This request ID was reused.") }
      return try JSONDecoder().decode(MobileLocalSessionCoordination.self, from: JSONEncoder().encode(result))
    }
    if let existing = state.localToolCoordinations?[targetID], existing.coordinatorID != callerID { throw WorkspaceToolError.coordinationConflict(existing.coordinatorID) }
    guard callerID != targetID else { throw WorkspaceToolError.invalid("A session cannot coordinate itself.") }
    var ancestor: String? = callerID; var seen = Set<String>()
    while let id = ancestor, seen.insert(id).inserted {
      if id == targetID { throw WorkspaceToolError.invalid("Local session coordination cannot form a cycle.") }
      ancestor = state.localToolCoordinations?[id]?.coordinatorID
    }
    let relation = MobileLocalSessionCoordination(coordinatorID: callerID, targetID: targetID, epoch: requestID, purpose: purpose, notifications: notifications)
    try transaction { next in
      var relations = next.localToolCoordinations ?? [:]; relations[targetID] = relation; next.localToolCoordinations = relations
      var receipts = next.toolReceipts ?? [:]; receipts[key] = .init(requestID: requestID, sessionID: callerID, arguments: arguments, response: .init(result: try MobileToolSupport.value(relation))); next.toolReceipts = receipts
    }
    return relation
  }
}
