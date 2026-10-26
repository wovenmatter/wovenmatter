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
      // Desktop/page captures and text belong to the model's tool response, not
      // the durable transport ledger. Record completion without those payloads.
      // A published page's small reference retains the ordinary retry receipt.
      let command = try? WovenMatterToolCommand(request.arguments)
      let htmlPublication = command?.group == .html
        && (try? JSONDecoder().decode(GatewayJSONValue.self, from: Data((command?.options["json"] ?? "").utf8)))?.objectValue?["action"]?.stringValue == "render"
      let automation = command?.group?.isAutomation == true && command?.action == "call" && !htmlPublication
      let receipt = automation ? WovenMatterToolResponse(success: false,
        error: "This automation call finished. Its output is not retained in the transport receipt. Inspect fresh state before further input; this request will not run again.",
        code: "automation_outcome_recorded", requestID: id) : response
      try await database.finishCompanionTool(receipt, requestID: id, deviceID: deviceID)
      return response
    }
    pending[key] = work
    defer { pending.removeValue(forKey: key) }
    return try await work.value
  }
}
