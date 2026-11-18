import Foundation
import Observation
import WovenMatterClient

// One open conversation is shared with the iPhone app (WovenMatterShared/PiBot).
typealias BotConversationKey = PiBotConversationKey
typealias BotConversationController = PiBotConversationController

/// Text and attachments not sent yet, keyed by bot and conversation.
@MainActor @Observable
final class BotDraftStore {
    struct Draft: Equatable {
        var text = ""
        var attachments: [PiBotAttachmentDraft] = []
    }
    private var drafts: [BotConversationKey: Draft] = [:]

    subscript(key: BotConversationKey) -> Draft {
        get { drafts[key] ?? Draft() }
        set { drafts[key] = newValue == Draft() ? nil : newValue }
    }
}
