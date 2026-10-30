import Foundation
import WovenMatterCore

/// The replica identity is a Mac, never a network address or a library authority.
/// SQL values travel as typed strings so Int64s and blobs survive JSON exactly.
public struct PairedLibraryValue: Codable, Equatable, Sendable {
  public let type: String
  public let value: String?
  public init(type: String, value: String? = nil) { self.type = type; self.value = value }
}

public struct PairedLibraryRecord: Codable, Equatable, Sendable {
  public let table: String
  public let key: String
  public let row: [String: PairedLibraryValue]
  public let deleted: Bool
  public let clock: Int64
  public let origin: String
  public let vector: [String: Int64]

  /// Causal updates supersede their predecessors. Concurrent deletion wins;
  /// concurrent edits have the same deterministic winner on every Mac.
  public func supersedes(_ other: Self) -> Bool {
    if dominates(other) { return true }
    if other.dominates(self) { return false }
    return outranks(other)
  }
  /// Deterministic order among concurrent maximal versions only.
  func outranks(_ other: Self) -> Bool {
    if deleted != other.deleted { return deleted }
    return clock == other.clock ? origin > other.origin : clock > other.clock
  }
  /// The causal frontier is the set of versions no other known version
  /// dominates. It is independent of arrival order, so choosing its winner here
  /// converges even when a later restore removes a previously winning deletion.
  static func frontier(_ versions: [Self]) -> [Self] {
    var result: [Self] = []
    for version in versions where !versions.contains(where: { $0.dominates(version) }) {
      if !result.contains(where: { $0.vector == version.vector }) { result.append(version) }
    }
    return result
  }
  static func winner(_ frontier: [Self]) -> Self? {
    frontier.reduce(nil) { best, version in best.map { version.outranks($0) ? version : $0 } ?? version }
  }
  public func dominates(_ other: Self) -> Bool {
    other.vector.allSatisfy { vector[$0.key, default: 0] >= $0.value }
      && vector.contains { $0.value > other.vector[$0.key, default: 0] }
  }
  public func concurrent(with other: Self) -> Bool {
    vector != other.vector && !dominates(other) && !other.dominates(self)
  }
}

public struct PairedLibraryPage: Codable, Sendable {
  public let schema: String
  public let entries: [PairedLibraryRecord]
  public let cursor: Int64
  public let hasMore: Bool
}

public struct PairedLibraryConflict: Codable, Identifiable, Sendable {
  public let id: String
  public let record: PairedLibraryRecord
}

/// Explicit content boundary. Runtime queues, checkpoints, credentials, local
/// identities, cursors and projections are deliberately absent from this list.
enum PairedLibraryTables {
  static let names = [
    "profiles", "surface_profiles", "folders", "folder_execution_roots", "notes", "dictation_history",
    "paired_agent_owners", "paired_conversation_owners", "dashboard_agents", "dashboard_conversations", "desktop_conversation_titles",
    "session_execution_roots", "dashboard_messages", "dashboard_message_attachments",
    "dashboard_message_references", "dashboard_runs", "dashboard_run_visible_context",
    "dashboard_run_events", "dashboard_run_trace_events", "workspace_history_events", "note_asset_versions",
    "workspace_tool_settings", "workspace_session_tools", "workspace_session_relationships",
    "workspace_session_grants", "workspace_session_goals", "workspace_goal_runs", "workspace_goal_usage",
    "paired_calendar_owners", "dashboard_calendar_items", "companion_calendar_owners", "companion_calendar_run_owners", "companion_calendar_runs",
    "companion_execution_workspaces", "companion_execution_journal", "companion_retained_settlements",
    "companion_execution_conversations", "companion_execution_adoptions", "companion_message_provenance",
    "companion_execution_runs", "companion_native_history", "companion_native_history_parts",
    "companion_saved_artifacts", "companion_artifact_uploads", "companion_artifact_chunks",
    "library_messages", "library_items", "library_locations", "paired_mac_routes", "paired_remote_workspaces"
  ]
}
