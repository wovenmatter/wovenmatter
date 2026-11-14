import Foundation
import WovenMatterCore

public extension WorkspaceConversationHistoryPage {
  /// The history page of a session another machine runs, from the
  /// transcript its owner streams (and any older pages read from it), so
  /// the conversation view renders it as it renders a session this Mac runs.
  init(remote transcript: LibraryTranscript) {
    let records = RemoteConversationRecords(transcript)
    self.init(conversationID: transcript.conversationID, messages: records.messages, runs: records.runs,
      activities: records.activities, attachments: records.attachments, hasOlderMessages: transcript.olderCursor != nil)
  }
}

public extension WorkspaceDatabase {
  /// One activity's complete projection, as `GET …/activity?id=&run=` answers
  /// it for a member's disclosure: the same read this Mac's own view makes.
  func libraryActivityDetails(conversationID: String, runID: String?, activityID: String) async throws -> LibraryActivity {
    guard let runID, !runID.isEmpty, activityID.utf8.count <= 512,
          let activity = try await conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: activityID) else {
      throw LibraryAPIError(code: "not_found", message: "This activity is not in the conversation.")
    }
    return LibraryActivity(id: activity.id, runID: runID, title: activity.title ?? activity.kind.rawValue,
      detail: activity.detail, status: activity.status ?? "",
      projectionJSON: String(decoding: try JSONEncoder().encode(activity), as: UTF8.self))
  }
}

public extension LibraryTranscript {
  /// `page` (older) followed by this transcript, each entity once; this
  /// transcript's live state wins.
  func prepending(_ page: LibraryTranscript) -> LibraryTranscript {
    var value = self
    let messageIDs = Set(messages.map(\.id)), activityIDs = Set(activities.map(\.id))
    value.messages = page.messages.filter { !messageIDs.contains($0.id) } + messages
    value.activities = page.activities.filter { !activityIDs.contains($0.id) } + activities
    let runIDs = Set((runs ?? []).map(\.id))
    let older = (page.runs ?? []).filter { !runIDs.contains($0.id) }
    if !older.isEmpty || runs != nil { value.runs = older + (runs ?? []) }
    value.olderCursor = page.olderCursor
    return value
  }
}
