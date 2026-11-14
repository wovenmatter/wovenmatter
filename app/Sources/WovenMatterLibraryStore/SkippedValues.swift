import Foundation
import WovenMatterCore

/// Devices of one library run different versions for days. Where this build
/// skips something a newer one wrote or asked for, it says so here: when the
/// number skipped changes, not on every read of the same values, and never
/// the values themselves.
enum SkippedValues {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var reported: [String: Int] = [:]
  static func report(_ count: Int, _ what: String) {
    guard count > 0 else { return }
    let changed = lock.withLock {
      guard reported[what] != count else { return false }
      reported[what] = count; return true
    }
    if changed { NSLog("Ignoring %ld %@", count, what) }
  }
}

extension WorkspaceToolGroup {
  /// The tool groups a caller selected (`X-Woven-Enabled-Groups`, a caller
  /// registration). A newer caller may name a group this build does not have.
  /// That name is ignored, not refused: the caller gets the tools of the
  /// groups both builds know, and fewer tools is always safe.
  public static func selected(_ names: [String]) -> Set<WorkspaceToolGroup> {
    let names = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let groups = names.compactMap(WorkspaceToolGroup.init(rawValue:))
    SkippedValues.report(names.count - groups.count, "tool group name(s) this build does not know")
    return Set(groups)
  }
}
