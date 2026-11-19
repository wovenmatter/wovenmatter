import Foundation
import WovenMatterCore

/// Execution ownership is positive. A shared row is executed, recovered,
/// scheduled or captured by this Mac only when its owner record names this
/// Mac's library identity. Unknown ownership, such as a partially received peer
/// import whose owner record has not arrived yet, is read-only.
///
/// An agent's `owner_device_id` uses the `device-id` identity and is
/// deliberately not compared with the library `host_device_id` here.
enum PairedLibraryOwnership {
  /// SQL boolean for a conversation executed natively by this Mac. Independent
  /// execution projections (Linux, iOS or another Mac) and retained imported
  /// history remain foreign even when this Mac manages their workspace.
  static func localConversation(_ column: String) -> String {
    """
    (EXISTS(SELECT 1 FROM conversation_owners own_c JOIN library_identity own_i ON own_i.singleton=1
       WHERE own_c.id=\(column) AND own_c.device_id=own_i.host_device_id)
     AND NOT EXISTS(SELECT 1 FROM execution_conversations own_x WHERE own_x.id=\(column))
     AND NOT EXISTS(SELECT 1 FROM retained_execution_history own_r WHERE own_r.conversation_id=\(column)))
    """
  }

  static func localCalendarItem(_ column: String) -> String {
    """
    EXISTS(SELECT 1 FROM calendar_item_owners own_k JOIN library_identity own_i ON own_i.singleton=1
      WHERE own_k.id=\(column) AND own_k.device_id=own_i.host_device_id)
    """
  }
}

extension WorkspaceDatabaseConnection {
  func locallyOwnsConversationUnlocked(_ id: String) throws -> Bool {
    try historyRowsUnlocked("SELECT 1 AS owned WHERE " + PairedLibraryOwnership.localConversation("?"), values: [id, id, id]).isEmpty == false
  }

  /// Claims for this Mac the rows that have no owner record, on every
  /// read-write open, from evidence only this Mac can hold. The insert triggers claim
  /// what a Mac creates; this covers rows older than the owner tables, on a
  /// library that may already hold other Macs' rows without owner records.
  /// There is no one-time marker: an owner record that exists or was received
  /// always wins, a row without evidence stays unclaimed (read-only), and a
  /// version's origin is never evidence, because any Mac may edit a row.
  /// - A conversation with a `harness_sessions` row and no execution
  ///   projection. That table is local, written only where the chat was
  ///   created, and emptied in a Dev snapshot, so two Macs claim disjoint
  ///   sets and a snapshot claims nothing.
  /// - A calendar item this Mac has run (`calendar_runs` is local) that no
  ///   executor record assigns to another device.
  /// - In a library that has never received peer data, every other calendar
  ///   item: this Mac's unless its executor record names another device (a
  ///   phone, or the placeholder a Dev snapshot writes), which keeps it.
  /// Agents are claimed where this Mac's device ID is known
  /// (`reconcileLocalCLIAgentCatalog`).
  func claimEvidencedOwnershipUnlocked() throws {
    let local = "(SELECT device_id FROM peer_sync_clock WHERE singleton=1)"
    let host = "(SELECT host_device_id FROM library_identity WHERE singleton=1)"
    try executeUnlocked("""
      INSERT OR IGNORE INTO conversation_owners(id,device_id)
        SELECT h.conversation_id,\(local) FROM harness_sessions h
        WHERE EXISTS(SELECT 1 FROM conversations c WHERE c.id=h.conversation_id)
          AND NOT EXISTS(SELECT 1 FROM conversation_owners o WHERE o.id=h.conversation_id)
          AND NOT EXISTS(SELECT 1 FROM execution_conversations x WHERE x.id=h.conversation_id);
      INSERT OR IGNORE INTO calendar_item_owners(id,device_id)
        SELECT i.id,\(local) FROM calendar_items i
        WHERE NOT EXISTS(SELECT 1 FROM calendar_item_owners o WHERE o.id=i.id)
          AND EXISTS(SELECT 1 FROM calendar_runs r WHERE r.event_id=i.id)
          AND NOT EXISTS(SELECT 1 FROM calendar_task_executors e WHERE e.event_id=i.id AND e.device_id<>\(host));
      INSERT OR IGNORE INTO calendar_item_owners(id,device_id)
        SELECT i.id,CASE WHEN e.device_id IS NULL OR e.device_id=\(host) THEN \(local) ELSE e.device_id END
        FROM calendar_items i LEFT JOIN calendar_task_executors e ON e.event_id=i.id
        WHERE NOT EXISTS(SELECT 1 FROM calendar_item_owners o WHERE o.id=i.id)
          AND NOT EXISTS(SELECT 1 FROM peer_sync_cursors)
          AND NOT EXISTS(SELECT 1 FROM peer_sync_versions WHERE pending_peer IS NOT NULL);
      """)
  }
}
