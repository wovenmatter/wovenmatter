import Foundation
import LibraryClient
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// Chats another machine runs, rendered by the same conversation view and
/// presentation as chats this Mac runs. Their live state is what the owner
/// streams (`federatedExecutionSnapshots`, kept current by the window's
/// `conversation` subscription); older pages are read from the owner on
/// scroll, and an activity's full projection when its disclosure opens.
@MainActor
final class RemoteConversationState {
    struct Older {
        /// Older pages belong to the cursor authority they were read from:
        /// the owner's live history while it is connected, else the saved archive.
        var online: Bool
        var transcript: LibraryTranscript
    }
    struct Detail {
        var version: Int64?
        var status: String?
        var value: AgentRunActivity
    }
    var older: [String: Older] = [:]
    var rendering: Set<String> = []
    var pending: Set<String> = []
    var opening: Set<String> = []
    var details: [String: Detail] = [:]
}

extension LocalACPSessionMetadata {
    /// A remote session's settings in the shape the composer's selectors and
    /// command palette read for a session this Mac runs.
    init(remote settings: SessionSettings) {
        func ids(_ options: [SessionSettingOption]) -> [String]? { options.isEmpty ? nil : options.map(\.id) }
        func labels(_ options: [SessionSettingOption]) -> [String: SessionOptionMetadata]? {
            options.isEmpty ? nil : Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.label, description: $0.description)) },
                uniquingKeysWith: { first, _ in first })
        }
        self.init(sessionKey: settings.conversationID, model: settings.model, thinking: settings.thinking,
            modelOptions: ids(settings.models), thinkingLevels: ids(settings.thinkingLevels),
            slashCommands: (settings.commands ?? []).map { LocalACPSlashCommand(name: $0.name, detail: $0.detail, argumentHint: $0.argumentHint) },
            modelOptionMetadata: labels(settings.models), thinkingOptionMetadata: labels(settings.thinkingLevels),
            permission: settings.permission, permissionOptions: ids(settings.permissions),
            permissionOptionMetadata: labels(settings.permissions))
    }
}

extension ApplicationModel {
    /// Another machine runs this chat.
    func isRemoteConversation(_ id: String) -> Bool { federatedExecutionOwners[id] != nil }

    /// What a remote chat shows now: older pages, then its owner's latest window.
    func remoteTranscript(_ id: String) -> LibraryTranscript? {
        guard let live = federatedExecutionSnapshots[id]?.transcript ?? windowLive.follows[id]?.transcript else { return nil }
        let online = federatedExecutionSnapshots[id]?.online == true
        guard let older = remoteConversations.older[id], older.online == online else { return live }
        return live.prepending(older.transcript)
    }

    /// Renders a remote chat into its conversation state. Calls coalesce:
    /// one render at a time per chat, and the latest state is always rendered.
    func renderRemoteConversation(_ id: String) {
        guard LocalExecutionRole.current != .backend, conversationStatesByID[id] != nil || windowLive.follows[id] != nil else { return }
        let remote = remoteConversations
        guard remote.rendering.insert(id).inserted else { remote.pending.insert(id); return }
        Task { @MainActor [weak self] in
            defer { remote.rendering.remove(id) }
            repeat {
                remote.pending.remove(id)
                await self?.renderRemoteConversationNow(id)
            } while remote.pending.contains(id)
        }
    }

    func renderRemoteConversationNow(_ id: String) async {
        guard let transcript = remoteTranscript(id) else { return }
        let state = ensureConversationState(id: id)
        let page = WorkspaceConversationHistoryPage(remote: transcript)
        var presentation: ConversationPresentation?
        var revision: UInt64
        repeat {
            revision = state.presentationRevision
            let previous = state.presentation
            presentation = await Task.detached(priority: .userInitiated) {
                Self.remotePresentation(page, previous: previous)
            }.value
            guard conversationStatesByID[id] === state else { return }
        } while state.presentationRevision != revision
        if let presentation { state.apply(presentation) }
    }

    /// The same window and presentations a page of this Mac's own history renders.
    nonisolated static func remotePresentation(_ page: WorkspaceConversationHistoryPage,
                                               previous: ConversationPresentation?) -> ConversationPresentation? {
        let window = ConversationWindow(page: page)
        guard previous?.window != window else { return nil }
        return ConversationPresentation(window: window,
            messagesByID: renderMessagePresentations(window.messages, activities: window.activities, runs: window.runs,
                reusing: previous?.messagesByID ?? [:]),
            runsByID: renderRunPresentations(window.runs, reusing: previous?.runsByID ?? [:]))
    }

    /// `refreshConversation` for a remote chat: render what its owner sent,
    /// reading its saved state first when nothing has arrived yet. False when
    /// there is nothing to render, so the projection's saved history shows.
    func refreshRemoteConversation(_ id: String) -> Bool {
        if remoteTranscript(id) != nil { renderRemoteConversation(id); return true }
        let remote = remoteConversations
        if federatedExecutionSnapshots[id] == nil, remote.opening.insert(id).inserted {
            Task { @MainActor [weak self] in
                defer { remote.opening.remove(id) }
                await self?.refreshFederatedConversation(id, reloadingConversation: false)
                self?.renderRemoteConversation(id)
            }
        }
        return false
    }

    /// Older messages of a remote chat, from its owner (or its saved archive while offline).
    func loadOlderRemoteMessages(_ id: String) async -> Bool {
        guard let state = conversationStatesByID[id], !state.isLoadingOlderMessages,
              let cursor = remoteTranscript(id)?.olderCursor else { return false }
        let online = federatedExecutionSnapshots[id]?.online == true
        state.setLoadingOlderMessages(true)
        defer { state.setLoadingOlderMessages(false) }
        do {
            let page: LibraryTranscript?
            if isBackendFrontend {
                page = try await sendBackendCommand(.federatedExecution(.earlier(conversationID: id, before: cursor))).federatedExecution?.transcript
            } else {
                page = try await performFederatedExecution(.earlier(conversationID: id, before: cursor)).transcript
            }
            guard let page, page.conversationID == id, conversationStatesByID[id] === state else { return false }
            let kept = remoteConversations.older[id].flatMap { $0.online == online ? $0.transcript : nil }
            remoteConversations.older[id] = .init(online: online, transcript: kept.map { $0.prepending(page) } ?? page)
            await renderRemoteConversationNow(id)
            return !page.messages.isEmpty
        } catch {
            state.setError(error.localizedDescription)
            return false
        }
    }

    /// An activity's full projection when its disclosure opens. A settled
    /// or versioned activity is read once per version; a live one again only
    /// when the owner reports a change.
    func remoteActivityDetails(conversationID: String, runID: String, activityID: String) async throws -> AgentRunActivity? {
        let current = conversationStatesByID[conversationID]?.runActivities
            .first { $0.runID == runID && $0.activity.id == activityID }?.activity
        let key = conversationID + "\n" + runID + "\n" + activityID
        if let cached = remoteConversations.details[key], let current,
           cached.version == current.detailVersion, cached.status == current.status,
           current.detailVersion != nil || ["completed", "failed", "cancelled", "interrupted"].contains(current.status ?? "") {
            return cached.value
        }
        let value: AgentRunActivity?
        if isBackendFrontend {
            value = try await sendBackendCommand(.federatedActivityDetails(conversationID: conversationID, runID: runID,
                activityID: activityID)).activityDetails
        } else {
            value = try await performFederatedActivityDetails(conversationID: conversationID, runID: runID, activityID: activityID)
        }
        guard let value else { return current }
        if remoteConversations.details.count > 256 { remoteConversations.details.removeAll() }
        remoteConversations.details[key] = .init(version: current?.detailVersion, status: current?.status, value: value)
        return value
    }

    /// The background server's side: the owner's details route over the
    /// member connection, or what history synchronized to this library holds.
    func performFederatedActivityDetails(conversationID: String, runID: String, activityID: String) async throws -> AgentRunActivity? {
        func decode(_ activity: LibraryActivity) throws -> AgentRunActivity? {
            try activity.projectionJSON.map { try JSONDecoder().decode(AgentRunActivity.self, from: Data($0.utf8)) }
        }
        var failure: (any Error)?
        if let client = try? memberExecutionClient() {
            do { return try decode(await client.activityDetails(conversationID: conversationID, runID: runID, activityID: activityID)) }
            catch { failure = error }
        }
        if let saved = try await libraryStore?.database.conversationActivityDetails(conversationID: conversationID,
            runID: runID, activityID: activityID) { return saved }
        if let failure { throw failure }
        return nil
    }
}
