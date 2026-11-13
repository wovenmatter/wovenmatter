import Foundation
import WovenMatterCore

/// Execution ownership is positive. A shared row is executed, recovered,
/// scheduled or captured by this Mac only when its owner record names this
/// Mac's library identity. Unknown ownership, such as a partially received peer
/// import whose owner record has not arrived yet, is read-only.
///
/// Native `owner_device_id` values use the `device-id` identity and are
/// deliberately not compared with the library `host_device_id` here.
enum PairedLibraryOwnership {
  /// SQL boolean for a conversation executed natively by this Mac. Independent
  /// execution projections (Linux, iOS or another Mac) and retained imported
  /// history remain foreign even when this Mac manages their workspace.
  static func localConversation(_ column: String) -> String {
    """
    (EXISTS(SELECT 1 FROM paired_conversation_owners own_c JOIN library_identity own_i ON own_i.singleton=1
       WHERE own_c.id=\(column) AND own_c.device_id=own_i.host_device_id)
     AND NOT EXISTS(SELECT 1 FROM execution_conversations own_x WHERE own_x.id=\(column))
     AND NOT EXISTS(SELECT 1 FROM retained_execution_history own_r WHERE own_r.conversation_id=\(column)))
    """
  }

  static func localCalendarItem(_ column: String) -> String {
    """
    EXISTS(SELECT 1 FROM paired_calendar_owners own_k JOIN library_identity own_i ON own_i.singleton=1
      WHERE own_k.id=\(column) AND own_k.device_id=own_i.host_device_id)
    """
  }
}

extension WorkspaceDatabaseConnection {
  func locallyOwnsConversationUnlocked(_ id: String) throws -> Bool {
    try historyRowsUnlocked("SELECT 1 AS owned WHERE " + PairedLibraryOwnership.localConversation("?"), values: [id, id, id]).isEmpty == false
  }
}
