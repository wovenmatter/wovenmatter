import Foundation
import WovenMatterCore

extension WorkspaceToolGroup {
  /// The tool groups a caller selected (`X-Woven-Enabled-Groups`, a caller
  /// registration), by name. A name that is no tool group is refused: every
  /// device runs the same build, so such a name is a mistake, and narrowing
  /// the selection to the names this build knows would hide it.
  public static func selected(_ names: [String]) throws -> Set<WorkspaceToolGroup> {
    var groups: Set<WorkspaceToolGroup> = []
    for name in names.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
      guard let group = WorkspaceToolGroup(rawValue: name) else {
        throw LibraryAPIError(code: "invalid_request", message: "The tool selection names a tool group Woven Matter does not have.")
      }
      groups.insert(group)
    }
    return groups
  }
}
