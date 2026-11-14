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
    // Privacy: when devices chose differently while apart, opting out of analytics wins.
    let candidates = frontier.contains(where: \.optsOutOfAnalytics) ? frontier.filter(\.optsOutOfAnalytics) : frontier
    return candidates.reduce(nil) { best, version in best.map { version.outranks($0) ? version : $0 } ?? version }
  }

  /// A product analytics preference that turns collection off.
  var optsOutOfAnalytics: Bool {
    guard table == "product_analytics_preference", !deleted, let value = row["payload"], value.type == "text",
          let text = value.value,
          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
    return object["enabled"] as? Bool == false
  }
  public func dominates(_ other: Self) -> Bool {
    other.vector.allSatisfy { vector[$0.key, default: 0] >= $0.value }
      && vector.contains { $0.value > other.vector[$0.key, default: 0] }
  }
}

/// The member a page came from. Records are relayed and their origins are
/// self-declared, so a receiver checks ownership-bearing rows against the
/// sender alone (`peerRecordAllowed`).
public struct PairedLibrarySender: Sendable {
  public let deviceID: String
  public let kind: MemberKind
  /// The receiver's current member list, to decide which workspace the sender serves.
  public let members: [MemberAudience.Member]
  public init(deviceID: String, kind: MemberKind, members: [MemberAudience.Member]) {
    self.deviceID = deviceID.lowercased(); self.kind = kind; self.members = members
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
    "surface_profiles", "folders", "folder_execution_roots", "notes", "dictation_history",
    "agent_owners", "conversation_owners", "agents", "conversations", "conversation_titles",
    "session_execution_roots", "messages", "message_attachments",
    "message_references", "runs", "run_visible_notes",
    "run_activities", "history_events", "note_asset_versions",
    "tool_settings", "session_tools", "session_relationships",
    "session_grants", "session_goals", "goal_runs", "goal_usage",
    "calendar_item_owners", "calendar_items", "calendar_task_executors", "calendar_run_publishers", "calendar_published_runs",
    "execution_workspaces", "execution_journal", "execution_retained_settlements",
    "execution_conversations", "execution_adoptions", "message_provenance",
    "execution_runs", "execution_native_history", "execution_native_history_parts",
    "saved_artifacts", "artifact_uploads", "artifact_chunks",
    "library_messages", "library_items", "library_locations", "mac_routes", "remote_workspace_configurations",
    // Signed member entries and revocations; trust is resolved from signatures.
    "library_members", "library_member_revocations",
    "bot_conversations", "bot_conversation_entries",
    // The analytics choice and its library-wide ID apply to every device.
    "product_analytics_preference"
  ]
}
