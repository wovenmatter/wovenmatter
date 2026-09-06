import Foundation
import Testing
@testable import WovenMatterCore

struct DashboardConversationSelectionTests {
  @Test("automatic panel selection uses activity only and excludes open conversations")
  func mostRecentAvailableConversation() throws {
    let conversations = try [
      conversation(
        id: "pinned-older",
        lastMessageAt: "2026-09-04T12:00:00Z",
        isPinned: true
      ),
      conversation(
        id: "open-newest",
        lastMessageAt: "2026-09-04T14:00:00Z"
      ),
      conversation(
        id: "available-newest",
        lastMessageAt: "2026-09-04T13:00:00Z"
      ),
      conversation(
        id: "archived-latest",
        lastMessageAt: "2026-09-04T15:00:00Z",
        isArchived: true
      ),
    ]

    let selection = DashboardConversationSelection
      .mostRecentAvailableConversationID(
        in: conversations,
        excluding: ["open-newest"]
      )

    #expect(selection == "available-newest")
    #expect(DashboardConversationSelection.mostRecentAvailableConversationID(
      in: conversations,
      excluding: ["pinned-older", "open-newest", "available-newest"]
    ) == nil)
  }

  @Test("selection preserves date precision and deterministic fallback ordering")
  func dateAndTieOrdering() throws {
    let fallback = try [
      conversation(id: "a", lastMessageAt: nil),
      conversation(id: "z", lastMessageAt: "invalid"),
    ]
    #expect(DashboardConversationSelection.mostRecentAvailableConversationID(
      in: fallback, excluding: []
    ) == "z")
    let dated = try fallback + [
      conversation(id: "later", lastMessageAt: "2026-09-04T13:00:00.500Z"),
      conversation(id: "earlier", lastMessageAt: "2026-09-04T13:00:00Z"),
      conversation(id: "tie-z", lastMessageAt: "2026-09-04T13:00:00.500Z"),
    ]
    for records in [dated, Array(dated.reversed())] {
      #expect(DashboardConversationSelection.mostRecentAvailableConversationID(
        in: records, excluding: []
      ) == "tie-z")
      #expect(DashboardConversationSelection.mostRecentAvailableConversationID(
        in: records, excluding: ["tie-z", "later"]
      ) == "earlier")
    }
    #expect(DashboardConversationSelection.mostRecentAvailableConversationID(
      in: [], excluding: []
    ) == nil)
  }

  private func conversation(
    id: String,
    lastMessageAt: String?,
    isPinned: Bool = false,
    isArchived: Bool = false
  ) throws -> WorkspaceConversationRecord {
    let json: [String: Any] = [
      "id": id,
      "title": id,
      "unread": false,
      "last_message_at": lastMessageAt as Any? ?? NSNull(),
      "is_pinned": isPinned,
      "is_archived": isArchived,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(WorkspaceConversationRecord.self, from: data)
  }
}
