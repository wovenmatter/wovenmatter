import Foundation

/// The format tag of a native history record (`NativeRecordPart.format`): which
/// kind of payload the record's bytes hold. Tags are stored in native history
/// rows and synced, so this is the one place that names them.
///
/// New records carry `name`. Rows already stored carry `earlierNames`; a reader
/// accepts those through `matches` or `names`, nothing writes them, and stored
/// rows are never rewritten to change a tag.
public struct NativeRecordFormat: Equatable, Sendable {
  /// The tag written on new records.
  public let name: String
  /// Names stored data only: the tags rows already stored carry for this format.
  public let earlierNames: [String]

  /// `name` and every earlier name, for a SQL `IN` filter over stored rows.
  public var names: [String] { [name] + earlierNames }

  /// Whether a stored record's tag is this format.
  public func matches(_ tag: String) -> Bool { tag == name || earlierNames.contains(tag) }

  private init(_ name: String, earlier earlierNames: [String]) {
    self.name = name; self.earlierNames = earlierNames
  }

  /// A complete activity: the record is the activity's own JSON object.
  public static let activity = NativeRecordFormat("wovenmatter.activity", earlier: ["wovenmatter.activity.v1"])
  /// A chained activity: an object that wraps the activity and, for a suffix,
  /// names the record that precedes it.
  public static let chainedActivity = NativeRecordFormat("wovenmatter.activity.chained", earlier: ["wovenmatter.activity.v2"])
  public static let piDurableEntry = NativeRecordFormat("pi-durable.entry", earlier: ["pi-durable.entry.v1"])
  public static let nativeUpdate = NativeRecordFormat("woven-native-update", earlier: ["woven-native-update-v1"])
  public static let fileManifest = NativeRecordFormat("woven-native-file-manifest",
    earlier: ["woven-native-file-manifest/v1", "woven-native-file-manifest/v2"])
  public static let fileChunk = NativeRecordFormat("woven-native-file-chunk", earlier: ["woven-native-file-chunk/v1"])
  public static let recordReference = NativeRecordFormat("woven-native-record-reference", earlier: ["woven-native-record-reference/v1"])
  public static let textFragment = NativeRecordFormat("woven-native-text-fragment", earlier: ["woven-native-text-fragment/v1"])
}
