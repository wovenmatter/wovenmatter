import Foundation

/// The format tag of a native history record (`NativeRecordPart.format`): which
/// kind of payload the record's bytes hold. Tags are stored in native history
/// rows and synced, so this is the one place that names them. Writers store
/// `name`; readers compare a record's tag with it.
public struct NativeRecordFormat: Equatable, Sendable {
  public let name: String

  private init(_ name: String) { self.name = name }

  /// A complete activity: the record is the activity's own JSON object.
  public static let activity = NativeRecordFormat("wovenmatter.activity")
  /// A chained activity: an object that wraps the activity and, for a suffix,
  /// names the record that precedes it.
  public static let chainedActivity = NativeRecordFormat("wovenmatter.activity.chained")
  public static let piDurableEntry = NativeRecordFormat("pi-durable.entry")
  public static let nativeUpdate = NativeRecordFormat("woven-native-update")
  public static let fileManifest = NativeRecordFormat("woven-native-file-manifest")
  public static let fileChunk = NativeRecordFormat("woven-native-file-chunk")
  public static let recordReference = NativeRecordFormat("woven-native-record-reference")
  public static let textFragment = NativeRecordFormat("woven-native-text-fragment")
}
