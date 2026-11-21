import Foundation
import WovenProtocol

extension Library {
  /// Every file, photo and link sent in a chat, oldest first: each user
  /// message's attachments, and the links in user and assistant text.
  public func libraryItems() async throws -> [LibraryItem] {
    try await read { db in
      let rows = try db.query("""
        SELECT i.id, i.session_id, i.body, i.created_at, s.title, s.machine_id, s.runtime
        FROM session_items i JOIN sessions s ON s.id = i.session_id
        WHERE i.deleted = 0 AND s.deleted = 0 AND i.kind IN ('userMessage', 'assistantMessage')
        ORDER BY i.created_at, i.id
        """)
      var items: [LibraryItem] = []
      for row in rows {
        guard let content = try? Wire.decoder.decode(ItemContent.self, from: Data((row.text("body") ?? "").utf8)) else { continue }
        let itemID = row.text("id") ?? ""
        let agent = LibraryAgent(machineID: row.text("machine_id") ?? "", runtime: RuntimeKind(rawValue: row.text("runtime") ?? ""))
        func item(_ index: Int, fromPerson: Bool, kind: LibraryItemKind, title: String, source: String,
                  attachment: Attachment?) -> LibraryItem {
          LibraryItem(id: "\(itemID):\(index)", sessionID: row.text("session_id") ?? "", sessionItemID: itemID,
                      sessionTitle: row.text("title") ?? "", agent: agent, fromPerson: fromPerson, kind: kind, title: title,
                      source: source, sentAt: row.date("created_at"), attachment: attachment)
        }
        let text: String, fromPerson: Bool
        var index = 0
        switch content {
        case .userMessage(let message, let attachments):
          text = message
          fromPerson = true
          for attachment in attachments {
            let kind: LibraryItemKind = attachment.mimeType.hasPrefix("image/") ? .photo : .file
            items.append(item(index, fromPerson: true, kind: kind, title: attachment.name, source: attachment.name,
                              attachment: attachment))
            index += 1
          }
        case .assistantMessage(let message):
          text = message
          fromPerson = false
        default:
          continue
        }
        for link in LibraryLinkDiscovery.links(in: text) {
          items.append(item(index, fromPerson: fromPerson, kind: link.kind, title: link.title, source: link.source,
                            attachment: nil))
          index += 1
        }
      }
      return items
    }
  }
}
