import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func enqueueConversationChange(
        _ change: DashboardConversationChange
    ) {
        if case .composerPrefill(let text) = change.phase {
            pendingComposerPrefills[change.conversationID] = text
            return
        }
        // Metadata changes are independent of run content and must not replace
        // or be suppressed by a pending terminal notification.
        if case .configuration(let configuration) = change.phase {
            // The running adapter already supplied this snapshot. Preparing a
            // session here would turn its initial notification into a refresh
            // loop, keeping the composer loading while idle sessions restart.
            localACPSessionMetadata[change.conversationID] = LocalACPSessionMetadata(
                sessionKey: change.conversationID,
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingLevels: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata
            )
            return
        }
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] == change.runID {
            return
        }
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] != change.runID {
            terminalRunIDsByConversation.removeValue(
                forKey: change.conversationID
            )
        }
        var pending = pendingConversationChanges[change.conversationID] ?? []
        if let last = pending.last, last.runID == change.runID {
            if last.phase == .terminal { return }
            pending[pending.count - 1] = change
        } else {
            pending.append(change)
        }
        pendingConversationChanges[change.conversationID] = pending
        guard conversationChangeWorkers[change.conversationID] == nil else {
            return
        }
        let conversationID = change.conversationID
        let token = UUID()
        conversationChangeWorkerTokens[conversationID] = token
        conversationChangeWorkers[conversationID] = Task { [weak self] in
            await self?.drainConversationChanges(
                conversationID: conversationID,
                token: token
            )
        }
    }

    private func drainConversationChanges(
        conversationID: String,
        token: UUID
    ) async {
        defer {
            if conversationChangeWorkerTokens[conversationID] == token {
                conversationChangeWorkers.removeValue(forKey: conversationID)
                conversationChangeWorkerTokens.removeValue(forKey: conversationID)
            }
        }
        while !Task.isCancelled,
              let next = pendingConversationChanges[conversationID]?.first {
            if next.phase == .content,
               let last = lastContentRefreshByConversation[conversationID] {
                let wait = Self.minimumContentRefreshInterval - last.duration(to: .now)
                if wait > .zero { try? await Task.sleep(for: wait) }
                if Task.isCancelled { return }
            }
            // Dequeue after the wait so a cancelled worker leaves the change queued.
            guard var pending = pendingConversationChanges[conversationID],
                  !pending.isEmpty else { return }
            let change = pending.removeFirst()
            if pending.isEmpty {
                pendingConversationChanges.removeValue(forKey: conversationID)
            } else {
                pendingConversationChanges[conversationID] = pending
            }
            if change.phase == .content,
               terminalRunIDsByConversation[conversationID] == change.runID {
                continue
            }
            await applyConversationChange(change)
            lastContentRefreshByConversation[conversationID] = .now
            if change.phase == .terminal {
                terminalRunIDsByConversation[conversationID] = change.runID
            }
        }
    }

    private func applyConversationChange(
        _ change: DashboardConversationChange
    ) async {
        await refreshConversation(id: change.conversationID)
        guard change.phase == .terminal else { return }
        if let dashboardStore {
            recoverPendingRemoteNoteEdit(
                runID: change.runID,
                conversationID: change.conversationID,
                store: dashboardStore
            )
        }
        await refreshWorkspaceIfChanged()
        finishAgentRunInteractions(conversationID: change.conversationID)
        trimConversationStateCacheIfNeeded()
        if let conversation = workspaceOverview?.conversations.first(where: {
            $0.id == change.conversationID
        }) {
            if openClawGatewayConversationIDs.contains(change.conversationID) {
                await refreshOpenClawGatewaySession(
                    conversationID: change.conversationID
                )
            } else if conversation.localRuntimeKind != nil {
                await refreshLocalACPSession(conversation: conversation)
            }
        }
        await refreshLocalUsage(
            range: currentUsageRange,
            refreshLimits: false,
            reason: .runCompleted
        )
    }

    private func recoverPendingRemoteNoteEdit(
        runID: String,
        conversationID: String,
        store: DashboardStore
    ) {
        guard flushNoteDrafts() else { return }
        guard let pending = (try? store.database.pendingRemoteNoteEdits())?
            .first(where: { $0.runID == runID }) else {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            return
        }
        do {
            if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                if adoptNoteEditingResponseDraft(response) {
                    Task { await refreshWorkspace() }
                }
            }
        } catch {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            ensureConversationState(id: conversationID).setError(
                "The agent response was saved, but its note edit was not applied: \(error.localizedDescription)"
            )
        }
    }

    func refreshWorkspace() async {
        await refreshWorkspace(force: true)
    }

    func refreshWorkspaceIfChanged() async {
        await refreshWorkspace(force: false)
    }

    func refreshWorkspace(force: Bool) async {
        if Date().timeIntervalSince(lastOpenClawCronRefresh) >= 30 {
            lastOpenClawCronRefresh = Date()
            Task { await refreshOpenClawCron() }
        }
        if Date().timeIntervalSince(lastHermesCronRefresh) >= 30 {
            lastHermesCronRefresh = Date()
            Task { await refreshHermesCron() }
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let priorRevision = force || workspaceOverview == nil ? nil : workspaceRevision
            if let snapshot = try await dashboardStore.snapshot(ifChangedFrom: priorRevision) {
                apply(snapshot)
            }
            let reconciledRunning = try await dashboardStore
                .activeAgentConversationIDs()
            if localRunningConversationIDs != reconciledRunning {
                localRunningConversationIDs = reconciledRunning
                trimConversationStateCacheIfNeeded()
            }
            if workspaceError != nil {
                workspaceError = nil
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    /// Reloads the visible window for `id`, rendering off the main actor and
    /// reusing unchanged message presentations from the previous window.
    func refreshConversation(id: String) async {
        let state = ensureConversationState(id: id)
        let generation = state.beginRefresh()
        guard let database = dashboardStore?.database else { return }
        let previous = state.presentation
        let limit = Self.initialConversationMessageLimit
        let work = Task.detached(priority: .userInitiated) { () throws -> DashboardConversationPresentation? in
            let page = try database.conversationHistoryPage(id: id, limit: limit)
            return Self.presentation(refreshing: previous, with: page)
        }
        do {
            let presentation = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            if let presentation { state.apply(presentation) }
            touchConversationState(state)
            state.setError(nil)
            if workspaceError != nil { workspaceError = nil }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            state.setError(error.localizedDescription)
        }
    }

    private nonisolated static func presentation(
        refreshing previous: DashboardConversationPresentation?,
        with page: WorkspaceConversationHistoryPage
    ) -> DashboardConversationPresentation? {
        let window = previous?.window.refreshing(with: page)
            ?? DashboardConversationWindow(page: page)
        guard previous?.window != window else { return nil }
        // A paged-back window keeps its earlier rows; a fresh one is rebuilt.
        let base = previous?.window.loadedOlderMessages == true ? previous : nil
        return DashboardConversationPresentation(
            window: window,
            messagesByID: (base?.messagesByID ?? [:]).merging(
                renderMessagePresentations(
                    page.messages, activities: page.activities, runs: page.runs,
                    reusing: previous?.messagesByID ?? [:]
                ),
                uniquingKeysWith: { _, new in new }
            ),
            runsByID: (base?.runsByID ?? [:]).merging(
                renderRunPresentations(page.runs, reusing: previous?.runsByID ?? [:]),
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    @discardableResult
    func loadOlderConversationMessages(id: String) async -> Bool {
        guard let state = conversationStatesByID[id],
              !state.isLoadingOlderMessages,
              let current = state.presentation,
              current.window.conversationID == id,
              current.window.hasOlderMessages,
              let cursor = current.window.messages.first.map({
                  WorkspaceConversationHistoryCursor(createdAt: $0.createdAt, messageID: $0.id)
              }),
              let dashboardStore else {
            return false
        }
        state.setLoadingOlderMessages(true)
        defer { state.setLoadingOlderMessages(false) }
        do {
            let database = dashboardStore.database
            let limit = Self.olderConversationMessageLimit
            let work = Task.detached(priority: .userInitiated) {
                let page = try database.conversationHistoryPage(id: id, before: cursor, limit: limit)
                return (
                    page: page,
                    messages: Self.renderMessagePresentations(
                        page.messages, activities: page.activities, runs: page.runs,
                        reusing: current.messagesByID
                    ),
                    runs: Self.renderRunPresentations(page.runs, reusing: current.runsByID)
                )
            }
            let rendered = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state,
                  let latest = state.presentation,
                  latest.window.conversationID == id else {
                return false
            }
            // Newer presentations win: `latest` may have advanced while paging.
            // A refresh still in flight captured a window without this prefix
            // and must not land on top of it. Superseding it also discards
            // whatever it carried, so read once more afterwards.
            _ = state.beginRefresh()
            state.apply(DashboardConversationPresentation(
                window: current.window.prepending(rendered.page).mergingNewer(latest.window),
                messagesByID: rendered.messages
                    .merging(current.messagesByID) { _, new in new }
                    .merging(latest.messagesByID) { _, new in new },
                runsByID: rendered.runs
                    .merging(current.runsByID) { _, new in new }
                    .merging(latest.runsByID) { _, new in new }
            ))
            touchConversationState(state)
            if workspaceError != nil { workspaceError = nil }
            await refreshConversation(id: id)
            return rendered.page.messages.isEmpty == false
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            state.setError(error.localizedDescription)
            return false
        }
    }

    func ensureConversationState(id: String) -> DashboardConversationState {
        if let state = conversationStatesByID[id] {
            touchConversationState(state)
            return state
        }
        let state = DashboardConversationState(conversationID: id)
        touchConversationState(state)
        conversationStatesByID[id] = state
        trimConversationStateCacheIfNeeded()
        return state
    }

    private func touchConversationState(_ state: DashboardConversationState) {
        conversationAccessSequence &+= 1
        state.lastAccessSequence = conversationAccessSequence
    }

    private func trimConversationStateCacheIfNeeded() {
        let inactive = conversationStatesByID.values
            .filter {
                !localRunningConversationIDs.contains($0.conversationID)
                    && !$0.isLoadingOlderMessages
            }
            .sorted { $0.lastAccessSequence < $1.lastAccessSequence }
        guard inactive.count > Self.maximumRetainedConversationCount else { return }
        for state in inactive.prefix(
            inactive.count - Self.maximumRetainedConversationCount
        ) {
            conversationStatesByID.removeValue(forKey: state.conversationID)
            lastContentRefreshByConversation.removeValue(forKey: state.conversationID)
        }
    }

    private nonisolated static func renderMessagePresentations(
        _ messages: [WorkspaceMessageRecord],
        activities: [WorkspaceRunActivityRecord],
        runs: [WorkspaceRunRecord],
        reusing previous: [String: DashboardMessagePresentation]
    ) -> [String: DashboardMessagePresentation] {
        var result: [String: DashboardMessagePresentation] = [:]
        let workRunsByReply = Dictionary(runs.compactMap { run in
            run.assistantMessageID.map { ($0, run.id) }
        }, uniquingKeysWith: { _, latest in latest })
        let activitiesByRun = Dictionary(grouping: activities.sorted(by: WorkspaceRunActivityRecord.precedes), by: \.runID)
        result.reserveCapacity(messages.count)
        for message in messages {
            guard !Task.isCancelled else { return result }
            // Older steering replies have no work disclosure of their own;
            // retain their complete canonical text instead of hiding commentary.
            let isAssistant = message.role == "assistant"
            let projection = isAssistant
                ? AssistantTranscriptProjection(
                    messageID: message.id,
                    content: message.content,
                    activities: (workRunsByReply[message.id].flatMap { activitiesByRun[$0] } ?? []).map(\.activity)
                )
                : nil
            let displayedBody = projection.map { workRunsByReply[message.id] == nil ? message.content : $0.body }
                ?? message.content
            let commentaryIDs = Set(projection?.commentary.map(\.id) ?? [])
            if let existing = previous[message.id],
               existing.source == message.content,
               existing.displayedBody == displayedBody,
               existing.status == message.status,
               existing.createdAt == message.createdAt,
               existing.commentaryIDs == commentaryIDs {
                result[message.id] = existing
                continue
            }
            result[message.id] = DashboardMessagePresentation(
                source: message.content,
                displayedBody: displayedBody,
                status: message.status,
                createdAt: message.createdAt,
                document: message.role == "assistant"
                    ? ConversationMarkdownDocument(
                        RemoteNoteEditEnvelope.redactingEnvelopes(in: displayedBody)
                    )
                    : nil,
                commentaryIDs: commentaryIDs,
                hasFinalReply: projection.map {
                    !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
            )
        }
        return result
    }

    private nonisolated static func renderRunPresentations(
        _ runs: [WorkspaceRunRecord],
        reusing previous: [String: DashboardRunPresentation]
    ) -> [String: DashboardRunPresentation] {
        var result: [String: DashboardRunPresentation] = [:]
        result.reserveCapacity(runs.count)
        for run in runs {
            guard !Task.isCancelled else { return result }
            if let existing = previous[run.id], existing.source == run {
                result[run.id] = existing
                continue
            }
            let startedAt = (run.startedAt ?? run.createdAt).flatMap(dashboardParsedDate)
            let completedDuration: String?
            if run.status != "running",
               let startedAt,
               let endValue = run.completedAt ?? run.updatedAt,
               let completedAt = dashboardParsedDate(endValue) {
                completedDuration = dashboardRunDuration(completedAt.timeIntervalSince(startedAt))
            } else {
                completedDuration = nil
            }
            result[run.id] = DashboardRunPresentation(
                source: run,
                startedAt: startedAt,
                completedDuration: completedDuration
            )
        }
        return result
    }

    func markConversationRead(id: String) {
        guard workspaceOverview?.conversations.first(where: { $0.id == id })?.unread == true else { return }
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.markConversationRead(id: id)
                await refreshWorkspace()
            } catch {
                workspaceError = error.localizedDescription
            }
        }
    }
}
