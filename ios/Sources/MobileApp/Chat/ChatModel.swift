import Foundation
import Observation
import WovenProtocol

/// What a new chat starts with: a runtime on a machine, or Quick Chat on this
/// device when `machineID` is nil.
struct ChatTarget: Hashable {
    var runtime: RuntimeKind
    var machineID: String?

    static let quickChat = ChatTarget(runtime: .piDurable, machineID: nil)

    var isQuickChat: Bool { machineID == nil }
}

/// The Chat tab: which chat it shows, what a new chat starts with, the drafts,
/// and sending. Sessions and their transcripts are the shared `SessionStore`s.
@MainActor
@Observable
final class ChatModel {
    /// The chat the tab shows; nil for a new chat.
    private(set) var sessionID: String?
    /// What the next new chat starts with.
    var target = ChatTarget.quickChat
    /// Drafts by chat id, "new" for the new chat.
    var drafts: [String: String] = [:]
    /// Files staged for the next message, by the same keys.
    var attachments: [String: [AgentMessageAttachmentDraft]] = [:]
    /// Quiet progress under a message just sent ("Starting on …").
    private(set) var progress: String?
    private(set) var isSending = false
    /// The last send that failed; the draft stays.
    var error: String?

    @ObservationIgnored private unowned let app: ApplicationModel

    init(app: ApplicationModel) {
        self.app = app
    }

    var draftKey: String { sessionID ?? "new" }

    /// The open chat's record, once the library lists it.
    var conversation: WorkspaceConversationRecord? { app.workspace.conversation(id: sessionID) }

    /// The open chat's live state.
    var session: SessionStore? { sessionID.map(app.sessions.session(for:)) }

    func open(_ sessionID: String) {
        self.sessionID = sessionID
        if let conversation = app.workspace.conversation(id: sessionID) {
            target = ChatTarget(runtime: conversation.runtime,
                                machineID: conversation.machineID == deviceID ? nil : conversation.machineID)
        }
        error = nil
        progress = nil
    }

    /// A new chat with `target`, shown at once; the session starts with its first message.
    func newChat(_ target: ChatTarget) {
        self.target = target
        sessionID = nil
        error = nil
        progress = nil
    }

    private var deviceID: String? { app.server?.remote?.machine.id }

    /// The name of the machine a target runs on, for captions.
    func machineName(_ target: ChatTarget) -> String {
        guard let machineID = target.machineID else { return "this device" }
        return app.machines.machine(id: machineID)?.name ?? "its machine"
    }

    /// Sends the draft. A new chat starts its session first, on the target's
    /// machine; the message shows as soon as the owner takes it.
    func send() async {
        let key = draftKey
        let text = drafts[key, default: ""]
        let staged = attachments[key] ?? []
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty else { return }
        isSending = true
        error = nil
        defer { isSending = false; progress = nil }
        do {
            let id: String
            if let sessionID {
                id = sessionID
            } else {
                let target = self.target
                if !target.isQuickChat { progress = "Starting on \(machineName(target))…" }
                guard let machineID = target.machineID ?? deviceID else { throw ClientError.notConnected }
                id = try await app.workspace.startSession(runtime: target.runtime, on: machineID, folderID: nil)
                drafts[key] = nil
                attachments[key] = nil
                drafts[id] = text
                attachments[id] = staged
                sessionID = id
            }
            let session = app.sessions.session(for: id)
            if !target.isQuickChat { progress = "Sending to \(machineName(target))…" }
            // The chat view follows the session; its owner answers within moments.
            for _ in 0..<100 where !session.isOwnerReachable { try await Task.sleep(for: .milliseconds(100)) }
            try await session.send(AgentMessageInput(text: text, attachments: staged))
            if drafts[id] == text { drafts[id] = nil }
            attachments[id] = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Uploads picked files to this device's library for the next message.
    func attach(_ files: [(url: URL, mimeType: String)]) async {
        let key = draftKey
        do {
            attachments[key, default: []] += try await app.sessions.stageMessageAttachments(files)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeAttachment(_ id: String) {
        attachments[draftKey]?.removeAll { $0.id == id }
    }
}
