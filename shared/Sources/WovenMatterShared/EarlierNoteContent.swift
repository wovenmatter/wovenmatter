import Foundation

/// The one-time conversion of note content stored by the release before this
/// one, which wrote a number under a top-level `version` key in every note
/// document. A document has no such member. Each device removes it once from
/// the notes it stores, when it converts its store, and every device uses this
/// function so the converted bytes are the same everywhere. This file is the
/// only place that names the key.
public enum EarlierNoteContent {
  /// `content` without its top-level `version` member and with every other
  /// byte unchanged (member order, spacing, a trailing `~sync` clock). Nil
  /// when there is nothing to remove: no such member, or not a JSON object.
  public static func removingVersionMember(_ content: String) -> String? {
    guard content.contains(#""version""#) else { return nil }
    let bytes = Array(content.utf8)
    var index = 0
    func skipSpace() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
    /// Moves past a string that starts at `index`; false when it never ends.
    func skipString() -> Bool {
      index += 1
      while index < bytes.count {
        if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
        if bytes[index] == UInt8(ascii: "\"") { index += 1; return true }
        index += 1
      }
      return false
    }
    /// Moves past one value: a string, an object or array with everything in it, or a bare token.
    func skipValue() -> Bool {
      var depth = 0
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\""): guard skipString() else { return false }
        case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; index += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          if depth == 0 { return true }
          depth -= 1; index += 1
        case UInt8(ascii: ","): if depth == 0 { return true }; index += 1
        default: index += 1
        }
        if depth == 0, index < bytes.count, [UInt8(ascii: ","), UInt8(ascii: "}")].contains(bytes[index]) { return true }
      }
      return false
    }
    skipSpace()
    guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
    index += 1
    var previousComma: Int?
    while true {
      skipSpace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
      let memberStart = index
      guard skipString() else { return nil }
      let isVersion = Array(bytes[memberStart..<index]) == Array(#""version""#.utf8)
      skipSpace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
      index += 1; skipSpace()
      guard skipValue() else { return nil }
      let valueEnd = index
      skipSpace()
      guard index < bytes.count else { return nil }
      let followed = bytes[index] == UInt8(ascii: ",")
      if isVersion {
        // With a member after it, the member and its comma go; as the last
        // member, the comma before it goes instead.
        let removed: Range<Int>
        if followed { index += 1; skipSpace(); removed = memberStart..<index }
        else { removed = (previousComma ?? memberStart)..<valueEnd }
        return String(decoding: bytes[..<removed.lowerBound] + bytes[removed.upperBound...], as: UTF8.self)
      }
      guard followed else { return nil }
      previousComma = index
      index += 1
    }
  }
}
