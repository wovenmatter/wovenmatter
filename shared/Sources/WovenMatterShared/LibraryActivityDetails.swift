import Foundation

/// Opaque native activity records. A complete activity is the activity's own
/// JSON object; a chained activity wraps an activity and may reference an
/// immutable predecessor for a suffix (`NativeRecordFormat`).
/// Storage backends must validate record scope, chunk manifests and digests
/// before supplying bytes. Reconstruction preserves the newest metadata.
public enum LibraryActivityDetails {
  public static var incomplete: LibraryAPIError {
    .init(code: "incomplete_activity_details", message: "Activity details are still syncing. Try again shortly.")
  }
  public static var invalid: LibraryAPIError {
    .init(code: "invalid_activity_details", message: "Activity details could not be verified. Try syncing again.")
  }
  // Native history permits 512 MiB records. Bound total work as well as each
  // record, while allowing thousands of small live suffixes between checkpoints.
  public static let maximumBytes = 512 * 1_024 * 1_024
  public static let maximumLinks = 16_384

  public static func reconstruct(recordID: String, activityID: String,
    read: (String) throws -> (format: String, data: Data)) throws -> Data {
    var next = recordID, visited = Set<String>(), suffixes: [String] = []
    var head: [String: Any]?, totalBytes = 0
    while true {
      guard !next.isEmpty, next.utf8.count <= 256, visited.count < maximumLinks,
        visited.insert(next).inserted else { throw invalid }
      let record = try read(next)
      guard record.data.count <= maximumBytes - totalBytes else { throw invalid }
      totalBytes += record.data.count
      guard let object = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any] else { throw invalid }
      let activity: [String: Any], previous: String?
      let complete = record.format == NativeRecordFormat.activity.name
      if complete {
        activity = object; previous = nil
        // A complete activity's disclosure returns the original projection unchanged.
        // A delta stored as a complete activity cannot be the base of a chain.
        guard visited.count == 1 || activity["contentIsDelta"] as? Bool != true else { throw invalid }
      } else if record.format == NativeRecordFormat.chainedActivity.name {
        guard let value = object["activity"] as? [String: Any],
          let delta = value["contentIsDelta"] as? Bool else { throw invalid }
        activity = value
        if delta {
          guard let pointer = object["previousDetailsRecordID"] as? String, !pointer.isEmpty else { throw invalid }
          previous = pointer
        } else {
          guard object["previousDetailsRecordID"] == nil else { throw invalid }
          previous = nil
        }
      } else { throw invalid }
      guard activity["id"] as? String == activityID else { throw invalid }
      if let head {
        guard activity["kind"] as? String == head["kind"] as? String else { throw invalid }
      } else { head = activity }
      // Preserve a complete activity's exact JSON, including non-text tool data,
      // when there is no chain. A chained activity always returns the inner
      // activity rather than its envelope.
      if visited.count == 1, previous == nil {
        return complete ? record.data : try JSONSerialization.data(withJSONObject: activity)
      }
      guard let content = activity["content"] as? String else { throw invalid }
      suffixes.append(content)
      if let previous { next = previous; continue }
      var assembled = head!
      assembled["content"] = suffixes.reversed().joined()
      assembled["contentIsDelta"] = false
      return try JSONSerialization.data(withJSONObject: assembled)
    }
  }
}
