import Foundation
import WovenMatterCore

/// Presentation only. Foreign sessions never enter the native execution store,
/// which prevents restoring, running, or publishing another owner's work.
enum DevelopmentLibraryProjection {
    static func conversation(_ value: CompanionConversation) throws -> WorkspaceConversationRecord {
        var fields: [String: Any] = ["id": value.id, "title": value.title, "unread": false,
            "is_pinned": value.isPinned ?? false, "is_archived": false, "is_scheduled_task": false,
            "last_message_at": value.updatedAt, "last_message_preview": value.preview]
        if let folderID = value.folderID { fields["folder_id"] = folderID }
        return try JSONDecoder().decode(WorkspaceConversationRecord.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
