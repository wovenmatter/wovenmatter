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

  /// SQL boolean for a registry ID (`workspace`, an SQL expression) that is a
  /// Mac's workspace. A chat's execution projection onto one is synthetic
  /// paired-Mac routing, derived from its owner record and rebuilt from it; a
  /// projection onto anything else (a Linux host, an iPhone, or a workspace
  /// not registered here) is an independent execution. A payload that is not
  /// JSON is not a Mac's and never an error: this also runs as a library opens.
  static func macWorkspace(_ workspace: String) -> String {
    """
    EXISTS(SELECT 1 FROM execution_workspaces own_w WHERE own_w.id=\(workspace)
      AND CASE WHEN json_valid(own_w.payload) THEN json_extract(own_w.payload,'$.kind') END='mac')
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
  /// - A conversation with a `harness_sessions` row and no independent
  ///   execution projection. That table is local, written only where the
  ///   chat was created (never for a paired placeholder), and emptied in a
  ///   Dev snapshot, so two Macs claim disjoint sets and a snapshot claims
  ///   nothing. A projection onto a Mac's workspace does not veto, as it
  ///   does not for `executesNativelyUnlocked`: earlier builds guessed
  ///   owners from an edit's origin and routed a Mac's own chats to another
  ///   Mac, which has no native session and so never claims them.
  /// - A calendar item one of whose runs this Mac reserved for itself or
  ///   sent, that no executor record assigns to another device.
  ///   `calendar_runs` is local, but it also holds the runs a Linux host
  ///   reported to the Mac that manages it (`importRemoteCalendarRunUnlocked`),
  ///   for items any Mac created; those are not evidence. A run is this
  ///   Mac's own when its task names no remote workspace (an imported run
  ///   always names one), or when this Mac sent it: its delivery
  ///   (`session_deliveries`, local, under the run's ID) exists only where
  ///   `prepareCalendarDelivery` ran. A run for a Linux workspace that was
  ///   reserved here and never sent cannot be told from an imported one and
  ///   is not counted.
  /// - In a library that has never received peer data, every other calendar
  ///   item: this Mac's unless its executor record names another device (a
  ///   phone, or the placeholder a Dev snapshot writes), which keeps it.
  /// Agents are claimed where this Mac's device ID is known
  /// (`reconcileLocalCLIAgentCatalog`).
  ///
  /// A chat this Mac owns keeps no projection onto a Mac's workspace. A
  /// receive removes one for the chats it touches (`projectConversationOwners`),
  /// but a claim is a local insert no receive follows, so stale routing is
  /// removed here the same way: as derived state, not as a deletion to send.
  func claimEvidencedOwnershipUnlocked() throws {
    let local = "(SELECT device_id FROM peer_sync_clock WHERE singleton=1)"
    let host = "(SELECT host_device_id FROM library_identity WHERE singleton=1)"
    try executeUnlocked("""
      INSERT OR IGNORE INTO conversation_owners(id,device_id)
        SELECT h.conversation_id,\(local) FROM harness_sessions h
        WHERE EXISTS(SELECT 1 FROM conversations c WHERE c.id=h.conversation_id)
          AND NOT EXISTS(SELECT 1 FROM conversation_owners o WHERE o.id=h.conversation_id)
          AND NOT EXISTS(SELECT 1 FROM execution_conversations x WHERE x.id=h.conversation_id
            AND NOT \(PairedLibraryOwnership.macWorkspace("x.workspace_id")));
      UPDATE peer_sync_clock SET applying=1 WHERE singleton=1;
      DELETE FROM execution_conversations
        WHERE \(PairedLibraryOwnership.macWorkspace("execution_conversations.workspace_id"))
          AND EXISTS(SELECT 1 FROM conversation_owners o WHERE o.id=execution_conversations.id AND o.device_id=\(host));
      UPDATE peer_sync_clock SET applying=0 WHERE singleton=1;
      INSERT OR IGNORE INTO calendar_item_owners(id,device_id)
        SELECT i.id,\(local) FROM calendar_items i
        WHERE NOT EXISTS(SELECT 1 FROM calendar_item_owners o WHERE o.id=i.id)
          AND EXISTS(SELECT 1 FROM calendar_runs r WHERE r.event_id=i.id AND (
            EXISTS(SELECT 1 FROM session_deliveries d WHERE d.id=r.id AND d.kind='calendar')
            OR CASE WHEN json_valid(r.task_json) THEN json_extract(r.task_json,'$.configuration.workspaceID') IS NULL ELSE 0 END))
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
