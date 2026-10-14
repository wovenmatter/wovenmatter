import Foundation
import WovenMatterCore

extension ApplicationModel {
    @discardableResult
    func mutateConversationGoal(id: String, mutation: WorkspaceGoalMutation,
                                dispatchFence suppliedFence: AgentDispatchFence? = nil) async throws -> WorkspaceGoal? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let starts: Bool
        switch mutation { case .set, .resume: starts = true; default: starts = false }
        let fence = starts ? suppliedFence ?? beginAgentDispatch(conversationID: id) : nil
        defer { if let fence, suppliedFence == nil { finishAgentDispatch(conversationID: id, fence: fence) } }
        if starts { try await waitForAgentStop(conversationID: id); try fence?.check() }
        if case .set = mutation { try await applyPendingSessionSelections(conversationID: id) }
        let stops: Bool
        switch mutation { case .pause, .clear, .edit: stops = true; default: stops = false }
        let goal: WorkspaceGoal?
        if stops {
            // Install the barrier before any await, and keep the mutation inside
            // it so a later Resume or user input observes the whole operation.
            let barrier = beginAgentStop(conversationID: id, afterStop: {
                _ = try await database.mutateGoal(sessionID: id, mutation: mutation)
            })
            try await barrier.value
            goal = try await database.sessionGoals().first { $0.sessionID == id }
        } else {
            try fence?.check()
            goal = try await database.mutateGoal(sessionID: id, mutation: mutation, dispatchFence: fence)
        }
        try await agentTools?.reload()
        await backendApplicationService?.invalidations.publish(scopes: [.settings], conversationIDs: [id])
        return goal
    }

    func handleConversationGoalCommand(_ command: WorkspaceGoalCommand, conversationID: String,
                                       dispatchFence: AgentDispatchFence) async throws -> Bool {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let goal = try await database.sessionGoals().first { $0.sessionID == conversationID }
        let mutation: WorkspaceGoalMutation
        switch command {
        case .show:
            guard goal != nil else { throw WorkspaceToolError.notFound("No goal is set. Use /goal followed by an objective.") }
            try await agentTools?.reload()
            return true
        case .set(let objective): mutation = .set(objective: objective, tokenBudget: nil, turnBudget: nil)
        case .pause, .resume, .clear:
            guard let goal else { throw WorkspaceToolError.notFound("No goal is set.") }
            switch command {
            case .pause: mutation = .pause(id: goal.id)
            case .resume: mutation = .resume(id: goal.id)
            default: mutation = .clear(id: goal.id)
            }
        }
        _ = try await mutateConversationGoal(id: conversationID, mutation: mutation, dispatchFence: dispatchFence)
        return true
    }

    private func blockGoalDelivery(_ delivery: WorkspaceSessionDelivery, reason: String) async {
        guard let database = dashboardStore?.database,
              let goal = try? await database.sessionGoals().first(where: { $0.sessionID == delivery.targetID }),
              goal.status == .active, goal.pendingDeliveryID == delivery.id else { return }
        _ = try? await database.mutateGoal(sessionID: goal.sessionID,
            mutation: .block(id: goal.id, evidence: String(reason.prefix(4_000))))
    }

    func runConversationGoals() async {
        guard !isBackendFrontend, !backendStopping, let database = dashboardStore?.database else { return }
        do {
            // Provider preparation, queued user sends and active tools retain precedence.
            let busy = runningToolSessionIDs.union(loadingLocalACPSessionIDs).union(updatingLocalACPSessionIDs).union(preparingAgentDispatchIDs)
            for delivery in try await database.dueGoalDeliveries(running: busy) {
                guard !Task.isCancelled, !backendStopping else { return }
                guard !preparingAgentDispatchIDs.contains(delivery.targetID) else { continue }
                do {
                    let response = try await dispatchToolDelivery(delivery)
                    if !response.success { await blockGoalDelivery(delivery, reason: response.error ?? "Goal dispatch failed.") }
                } catch {
                    await blockGoalDelivery(delivery, reason: error.localizedDescription)
                }
            }
            let previous = agentTools?.goals
            try await agentTools?.reload()
            if previous != agentTools?.goals {
                await backendApplicationService?.invalidations.publish(scopes: [.settings])
            }
        } catch { agentTools?.error = error.localizedDescription }
    }
}
