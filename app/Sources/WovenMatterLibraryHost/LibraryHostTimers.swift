import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Timers fire on the machine whose library holds them (timers are not synced):
/// the library host decides what is due and records each occurrence, and the
/// Node server delivers it to its own session or to one of this machine's bots,
/// then settles it. A Linux session's or bot's timers need no Mac.
/// See docs/architecture/WOVEN_EVERYWHERE.md, "Timers on a library host".
public struct LibraryHostTimers: Sendable {
  public struct Occurrence: Codable, Equatable, Sendable {
    public var timerID: String
    /// The occurrence's stable ID: the delivery receipt, the Node server's
    /// command identity and the bot runtime's `deliveryId`, so a retry never repeats it.
    public var deliveryID: String
    /// A session (conversation UUID) or a bot principal `woven:bot:<machine>:<bot>`.
    public var target: String
    public var kind: String
    public var botID: String?
    public var text: String
  }
  public struct Due: Codable, Equatable, Sendable {
    public var occurrences: [Occurrence]
    /// The next time any active timer fires, so the server can sleep until then (ISO 8601).
    public var nextFireAt: String?
  }
  public struct Settlement: Codable, Sendable {
    public var timerID: String
    public var deliveryID: String
    /// `accepted` (delivered), `retry` (not delivered; offered again in 30 s) or
    /// `cancelled` (this machine cannot deliver it; a one-shot timer ends).
    public var outcome: String
    public var reason: String?
  }

  let database: WorkspaceDatabase
  let machineID: String

  public init(database: WorkspaceDatabase, machineID: String) {
    self.database = database; self.machineID = machineID.lowercased()
  }

  /// Every occurrence that is due now and not yet delivered, claimed for delivery.
  public func due(now: Date = Date()) async throws -> Due {
    var occurrences: [Occurrence] = []
    for timer in try await database.dueSessionTimers(now: now) {
      guard let id = timer.pendingDeliveryID, try await database.isTimerOccurrenceActive(id: timer.id, deliveryID: id) else { continue }
      let bot = WovenMCPCaller.parseBot(timer.sessionID)
      // Another machine's bot is delivered by that machine.
      if let bot, bot.machineID != machineID { continue }
      var delivery = try await database.toolDelivery(id: id)
      if delivery == nil {
        delivery = try await database.reserveToolDelivery(sourceID: timer.sessionID, targetID: timer.sessionID,
          text: timer.instruction, requestID: id, kind: .timer)
      }
      guard let delivery else { continue }
      if ["accepted", "cancelled"].contains(delivery.status) {
        try await database.finishTimerOccurrence(id: timer.id, deliveryID: id, now: now)
        continue
      }
      // A claim left `sending` by a server that stopped mid-delivery is offered
      // again: delivery is idempotent by `deliveryID`.
      if delivery.status == "queued" { guard try await database.claimToolDelivery(id: id, now: now) != nil else { continue } }
      else if delivery.status != "sending" { continue }
      occurrences.append(.init(timerID: timer.id, deliveryID: id, target: timer.sessionID, kind: bot == nil ? "session" : "bot",
        botID: bot?.botID, text: timer.instruction))
    }
    let next = try await database.sessionTimers().filter { !$0.isPaused && $0.pendingDeliveryID == nil }.map(\.nextFireAt).min()
    return .init(occurrences: occurrences, nextFireAt: next.map { ISO8601DateFormatter().string(from: $0) })
  }

  public func settle(_ settlement: Settlement, now: Date = Date()) async throws {
    guard UUID(uuidString: settlement.deliveryID) != nil, UUID(uuidString: settlement.timerID) != nil,
          settlement.reason.map({ $0.utf8.count <= 1_024 }) ?? true else {
      throw LibraryAPIError(code: "invalid_request", message: "Settle a timer occurrence by its timer and delivery IDs.")
    }
    switch settlement.outcome {
    case "accepted": try await database.setToolDeliveryStatus(id: settlement.deliveryID, status: "accepted")
    case "cancelled":
      try await database.setToolDeliveryStatus(id: settlement.deliveryID, status: "cancelled",
        failureCode: "not_deliverable", failureReason: settlement.reason ?? "This machine cannot deliver to the timer's session.")
    case "retry": try await database.failToolDeliveryAttempt(id: settlement.deliveryID, now: now); return
    default: throw LibraryAPIError(code: "invalid_request", message: "A timer outcome is accepted, retry or cancelled.")
    }
    try await database.finishTimerOccurrence(id: settlement.timerID, deliveryID: settlement.deliveryID, now: now)
  }
}
