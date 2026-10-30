import Foundation

/// Rebind only typed library identity fields. Workspace IDs, native record bytes,
/// user-authored content and opaque provider data are never text-replaced.
public enum CompanionLibraryJSON {
  public static func rewrite(_ data: Data, from previous: String, to current: String) throws -> Data {
    guard previous != current else { return data }
    func visit(_ value: Any) -> Any {
      if let object = value as? [String: Any] {
        return object.mapValuesWithKeys { key, value in
          if ["libraryID", "workspaceID"].contains(key), value as? String == previous { return current }
          return visit(value)
        }
      }
      if let values = value as? [Any] { return values.map(visit) }
      return value
    }
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: visit(value), options: [.sortedKeys, .fragmentsAllowed])
  }
}

private extension Dictionary where Key == String, Value == Any {
  func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
  }
}
