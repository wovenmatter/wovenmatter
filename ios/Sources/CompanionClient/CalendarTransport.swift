import Foundation
import WovenMatterCompanion

public protocol CompanionCalendarTransport: Sendable {
  func calendarPublishRuns(_ runs: [CompanionCalendarRun]) async throws -> [String]
  func calendarSnapshot() async throws -> CompanionCalendarSnapshot
  func calendarMutate(_ mutation: CompanionCalendarMutation) async throws -> CompanionCalendarReceipt
}
extension HTTPSCompanionTransport: CompanionCalendarTransport {
  public func calendarPublishRuns(_ runs: [CompanionCalendarRun]) async throws -> [String] {
    try await request("v1/calendar/runs", method: "POST", body: JSONEncoder().encode(runs))
  }
  public func calendarSnapshot() async throws -> CompanionCalendarSnapshot { try await request("v1/calendar") }
  public func calendarMutate(_ mutation: CompanionCalendarMutation) async throws -> CompanionCalendarReceipt {
    try await request("v1/calendar/mutations", method: "POST", body: JSONEncoder().encode(mutation))
  }
}
