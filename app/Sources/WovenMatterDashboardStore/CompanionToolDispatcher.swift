import Foundation
import WovenMatterCore

/// Client disconnects do not cancel accepted work. Stable receipts prevent a
/// lost HTTP reply (or host restart) from executing a tool mutation twice.
@MainActor
public final class CompanionToolDispatcher {
  public let database: WorkspaceDatabase
  private var pending: [String: Task<WovenMatterToolResponse, any Error>] = [:]

  public init(database: WorkspaceDatabase) { self.database = database }

  public func execute(_ value: CompanionToolRequest, deviceID: String,
                      perform: @escaping @MainActor (WovenMatterToolRequest, String) async -> WovenMatterToolResponse) async throws -> WovenMatterToolResponse {
    let reservation = try await database.reserveCompanionTool(value, deviceID: deviceID)
    let id = UUID(uuidString: value.request.requestID)!.uuidString.lowercased()
    let key = deviceID + ":" + id
    // Reservation validates payload and current authority before joining work.
    if let response = reservation.response { return response }
    if let task = pending[key] { return try await task.value }
    guard reservation.isNew else {
      return .init(success: false,
        error: "The central Mac accepted this tool call but its result was not recorded. Inspect the affected item before issuing another request; this request will not execute again.",
        code: "outcome_unknown", requestID: id)
    }
    var request = value.request
    request.requestID = id
    let work = Task { [database] in
      let response = await perform(request, value.conversationID).bounded()
      try await database.finishCompanionTool(response, requestID: id, deviceID: deviceID)
      return response
    }
    pending[key] = work
    defer { pending.removeValue(forKey: key) }
    return try await work.value
  }
}
