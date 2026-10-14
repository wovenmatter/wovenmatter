import Foundation
import WovenMatterCore

extension ApplicationModel {
    @discardableResult
    func mutateConversationGoal(id: String, mutation: WorkspaceGoalMutation) async throws -> WorkspaceGoal? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        if case .set = mutation { try await applyPendingSessionSelections(conversationID: id) }
        let previousGoal = try await database.sessionGoals().first { $0.sessionID == id }
        let goal = try await database.mutateGoal(sessionID: id, mutation: mutation)
        if case .pause = mutation { try await beginAgentStop(conversationID: id).value }
        // Changing or removing a goal stops any old goal work before another objective starts.
        if case .edit = mutation { try await beginAgentStop(conversationID: id).value }
        if case .clear = mutation, previousGoal?.status == .active { try await beginAgentStop(conversationID: id).value }
        try await agentTools?.reload()
        await backendApplicationService?.invalidations.publish(scopes: [.settings], conversationIDs: [id])
        return goal
    }

    func handleConversationGoalCommand(_ command: WorkspaceGoalCommand, conversationID: String) async throws -> Bool {
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
        _ = try await mutateConversationGoal(id: conversationID, mutation: mutation)
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
