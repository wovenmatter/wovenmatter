import Foundation
import CryptoKit

/// A cache is a display projection, never the durable source of tool output.
/// Keep identities, order, status, and file metadata while fetching full details
/// from their journal record only when a disclosure is opened.
public enum CompanionTranscriptCompaction {
  public static func activity(_ value: CompanionActivity, textLimit: Int = 512) -> CompanionActivity {
    var result = value
    result.detail = value.detail.map { String($0.prefix(textLimit)) }
    guard let text = value.projectionJSON,
          var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return result }
    var changed = result.detail != value.detail
    for key in ["rawInputJSON", "rawOutputJSON", "rawPayloadJSON"] {
      if object.removeValue(forKey: key) != nil { changed = true }
    }
    func bounded(_ value: Any) -> Any {
      if let text = value as? String, text.count > textLimit { changed = true; return String(text.prefix(textLimit)) }
      if let values = value as? [[String: Any]] { return values.map { $0.mapValues(bounded) } }
      if let value = value as? [String: Any] { return value.mapValues(bounded) }
      return value
    }
    for key in ["content", "detail", "subagents", "planEntries"] {
      if let value = object[key] { object[key] = bounded(value) }
    }
    if let changes = object["changes"] as? [[String: Any]] {
      object["changes"] = changes.map { change in
        var change = change
        for key in ["oldText", "newText", "unifiedDiff"] {
          if let text = change[key] as? String, !text.isEmpty { changed = true; change.removeValue(forKey: key) }
        }
        change["newText"] = ""
        return change
      }
    }
    if changed {
      object["detailsAvailable"] = true
      let digest = SHA256.hash(data: Data(text.utf8))
      object["detailVersion"] = digest.prefix(8).reduce(Int64(0)) { ($0 &<< 8) | Int64($1) }
    }
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
      result.projectionJSON = String(decoding: data, as: UTF8.self)
    }
    return result
  }
}
