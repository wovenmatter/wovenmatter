import Foundation

/// A stop-time selection. Text typed elsewhere while STT finishes is preserved.
/// Overlapping edits require an explicit insertion rather than overwriting work.
public struct DictationInsertion: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    public init(text: String, selection: NSRange) { self.text = text; self.selection = selection }
    public func range(in current: String) -> NSRange? {
        let old = Array(text.utf16), new = Array(current.utf16)
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= old.count, selection.length <= old.count - selection.location else { return nil }
        if old == new { return selection }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let end = old.count - suffix
        if end < selection.location {
            return NSRange(location: selection.location + new.count - old.count, length: selection.length)
        }
        if prefix > NSMaxRange(selection) { return selection }
        return nil
    }
}
