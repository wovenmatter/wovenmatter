import Foundation
import WovenMatterCore

/// A value-only receipt crosses the database worker boundary. SQL and rollback
/// remain on the same writer lane; callers never receive a SQLite connection.
struct LocalACPSteeringReservation: Sendable {
  let identifiers: LocalACPSteeringIdentifiers
  let previous: [String: String?]
  let deliveryID: String?
  let newAttachmentGrants: Set<String>
}

extension WorkspaceDatabase {
  typealias SteeringReservation = LocalACPSteeringReservation

  func reserveLocalACPSteeringTurn(runID: String, input: AgentMessageInput,
    completesPreviousAssistant: Bool = true) async throws -> SteeringReservation {
    try await write {
      try $0.reserveLocalACPSteeringTurn(runID: runID, input: input,
        completesPreviousAssistant: completesPreviousAssistant)
    }
  }

  @discardableResult
  func rejectLocalACPSteeringTurn(_ reservation: SteeringReservation) async throws -> Bool {
    // Stop may cancel the admission task after its reservation was committed.
    // Settling that durable receipt must still reach the writer.
    try await finishWrite { try $0.rejectLocalACPSteeringTurn(reservation) }
  }
}
