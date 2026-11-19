import Foundation

/// One-time carry-over of saved fields that v0.4.2 named after a "central"
/// library: the phone's store and a workspace journal (the iPhone's, and each
/// Mac's command journal) are read under the new names, and the next save
/// writes only those.
enum PersistedFieldRenames {
  static let store = ["centralConversationIDs": "libraryConversationIDs",
                      "centralDeletedConversationIDs": "libraryDeletedConversationIDs"]
  static let journal = ["centralCursor": "libraryCursor", "centralWorkspaceRevisions": "libraryWorkspaceRevisions"]

  /// `data` with each old key renamed inside the saved index's `state`.
  /// Returned unchanged, byte for byte, when no old key is present or `data`
  /// is not a saved index (an object holding a `state` object).
  static func upgrade(_ data: Data, renaming keys: [String: String]) -> Data {
    guard keys.keys.contains(where: { data.range(of: Data("\"\($0)\"".utf8)) != nil }),
          var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var state = root["state"] as? [String: Any] else { return data }
    var changed = false
    for (old, new) in keys {
      guard let value = state.removeValue(forKey: old) else { continue }
      if state[new] == nil { state[new] = value }
      changed = true
    }
    root["state"] = state
    guard changed, let upgraded = try? JSONSerialization.data(withJSONObject: root) else { return data }
    return upgraded
  }
}
