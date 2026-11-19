import Foundation
import WovenMatterShared

public protocol LibraryCalendarTransport: Sendable {
  func calendarPublishRuns(_ runs: [LibraryCalendarRun]) async throws -> [String]
  func calendarSnapshot() async throws -> LibraryCalendarSnapshot
  func calendarMutate(_ mutation: LibraryCalendarMutation) async throws -> LibraryCalendarReceipt
}
extension HTTPSLibraryTransport: LibraryCalendarTransport {
  public func calendarPublishRuns(_ runs: [LibraryCalendarRun]) async throws -> [String] {
    try await request("calendar/runs", method: "POST", body: JSONEncoder().encode(runs))
  }
  public func calendarSnapshot() async throws -> LibraryCalendarSnapshot { try await request("calendar") }
  public func calendarMutate(_ mutation: LibraryCalendarMutation) async throws -> LibraryCalendarReceipt {
    try await request("calendar/mutations", method: "POST", body: JSONEncoder().encode(mutation))
  }
}
