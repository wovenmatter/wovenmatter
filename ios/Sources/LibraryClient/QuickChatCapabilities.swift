import Foundation
import WovenMatterShared

/// A fixed capability boundary, enforced when advertising and dispatching tools.
/// Saved grants cannot restore the former on-device coding environment.
public enum QuickChatCapabilities {
  public static let webSelection = "quick_chat_web"
  /// Woven tool groups Quick Chat provides. Everything else stays with Mac and Linux agents.
  public static let groups: [WorkspaceToolGroup] = [.notes, .timers, .calendar]
  public static let options: [LibrarySelection] = [
    .init(id: "woven_notes", label: "Notes"),
    .init(id: "woven_timers", label: "Timers and reminders"),
    .init(id: "woven_calendar", label: "Calendar"),
    .init(id: webSelection, label: "Web search and reading")
  ]
  /// Native tools that are always available inside the boundary.
  public static let nativeTools: Set<String> = ["ask_user", "clock"]
  public static var toolNames: Set<String> {
    Set(WovenMCPCatalog.tools.filter { $0.group.map(groups.contains) == true }.map(\.name))
      .union(["woven_context", "web_search", "web_read"]).union(nativeTools)
  }
  public static func enabled(_ name: String, selection: [String]?) -> Bool {
    if nativeTools.contains(name) { return true }
    let selected = MobileToolSupport.migratedMCPSelection(selection)
    if name == webSelection || name == "web_search" || name == "web_read" {
      return selected.map { $0.contains(webSelection) || $0.contains(name) } ?? true
    }
    if name == "woven_context" {
      return selected.map { $0.contains("woven_notes") || $0.contains("woven_notes_read") || $0.contains(name) } ?? true
    }
    let groupID = groups.first { "woven_" + $0.rawValue == name }
    let group = groupID ?? WovenMCPCatalog.tools.first { $0.name == name }?.group
    guard let group, groups.contains(group), groupID != nil || toolNames.contains(name) else { return false }
    let selection = "woven_" + group.rawValue
    return selected.map { values in
      values.contains(selection) || values.contains(name)
        // A group control describes an existing partial grant without expanding it.
        || groupID != nil && values.contains { toolNames.contains($0) && $0.hasPrefix(selection + "_") }
    } ?? true
  }
}
