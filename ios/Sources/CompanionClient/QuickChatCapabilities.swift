import Foundation
import WovenMatterCompanion

/// A fixed capability boundary, enforced when advertising and dispatching tools.
/// Saved grants cannot restore the former on-device coding environment.
public enum QuickChatCapabilities {
  public static let webSelection = "quick_chat_web"
  public static let options: [CompanionSelection] = [
    .init(id: "woven_notes", label: "Notes"),
    .init(id: webSelection, label: "Web search and reading")
  ]
  public static var toolNames: Set<String> {
    Set(WovenMCPCatalog.tools.filter { $0.group == .notes }.map(\.name))
      .union(["woven_context", "web_search", "web_read", "ask_user"])
  }
  public static func enabled(_ name: String, selection: [String]?) -> Bool {
    if name == "ask_user" { return true }
    let selected = MobileToolSupport.migratedMCPSelection(selection)
    if name == webSelection || name == "web_search" || name == "web_read" {
      return selected.map { $0.contains(webSelection) || $0.contains(name) } ?? true
    }
    guard name == "woven_notes" || toolNames.contains(name) else { return false }
    return selected.map { values in
      values.contains("woven_notes") || values.contains(name)
        || name == "woven_notes" && values.contains(where: { toolNames.contains($0) && $0.hasPrefix("woven_notes_") })
        || name == "woven_context" && values.contains("woven_notes_read")
    } ?? true
  }
}
