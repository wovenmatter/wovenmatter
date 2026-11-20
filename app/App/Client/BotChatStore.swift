import Foundation
import Observation

struct BotConversationKey: Hashable, Sendable {
    /// The bots' home machine.
    let machineID: String
    let botID: String
    /// nil is the bot's main channel, or the Forum itself.
    let conversationID: Int?
}

/// One open bot conversation: its history, the reply being written, and messages not yet
/// recorded. Fed by a subscription on the home machine's server while a pane shows it.
@MainActor
@Observable
final class BotChatStore {
    let key: BotConversationKey
    private(set) var state = PiBotConversationState()
    /// A thread's starting message.
    private(set) var origin: PiBotDisplayEntry?
    private(set) var viewedID: Int?
    private(set) var mainID: Int?
    private(set) var loading = true
    private(set) var sending = false
    private(set) var stopping = false
    var error: String?

    @ObservationIgnored private var viewers = 0

    init(key: BotConversationKey) { self.key = key }

    var isThread: Bool { viewedID != nil && mainID != nil && viewedID != mainID }
    /// Ready to take a message: subscribed, loaded, and showing the conversation asked for.
    private(set) var isReady = false

    /// In a thread, only what was said in the thread. Inherited history stays with its parent.
    var visibleEntries: [PiBotDisplayEntry] {
        isThread ? state.entries.filter { $0.conversationId == viewedID } : state.entries
    }

    func attach() { viewers += 1 }
    func detach() { viewers = max(0, viewers - 1) }

    /// Reports whether the server took the message, so the composer keeps it otherwise.
    func send(text: String, context: String?) async -> Bool {
        if text.count > PiBotAttachmentDraft.maxMessageCharacters {
            error = "Message and attachments must total fewer than 100,000 characters."
            return false
        }
        error = ClientError.notConnected.localizedDescription
        return false
    }

    func stop() async {
        error = ClientError.notConnected.localizedDescription
    }

    func startThread(from entry: PiBotDisplayEntry) async -> PiBotThread? {
        error = ClientError.notConnected.localizedDescription
        return nil
    }
}

/// One open Forum room: the Forum itself or one of its threads.
@MainActor
@Observable
final class ForumRoomStore {
    struct Pending: Equatable, Identifiable, Sendable {
        let id: Int
        let text: String
    }

    let key: BotConversationKey
    private(set) var state = PiBotForumRoomState()
    private(set) var loading = true
    private(set) var sending = false
    private(set) var loadingEarlier = false
    /// Posts sent and not yet back from the server.
    private(set) var pending: [Pending] = []
    private(set) var isReady = false
    var error: String?

    @ObservationIgnored private var viewers = 0

    init(key: BotConversationKey) { self.key = key }

    var isThread: Bool { key.conversationID != nil }

    func attach() { viewers += 1 }
    func detach() { viewers = max(0, viewers - 1) }

    /// Reports whether the server took the post, so the composer keeps it otherwise.
    func send(text: String, mentions: [String], everyone: Bool) async -> Bool {
        if text.count > PiBotAttachmentDraft.maxMessageCharacters {
            error = "Message and attachments must total fewer than 100,000 characters."
            return false
        }
        error = ClientError.notConnected.localizedDescription
        return false
    }

    func loadEarlier() async {}

    func startThread(from post: PiBotForumPost) async -> PiBotForumThread? {
        error = ClientError.notConnected.localizedDescription
        return nil
    }
}

/// Text and attachments not sent yet, keyed by bot and conversation.
@MainActor
@Observable
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
