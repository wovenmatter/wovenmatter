import Foundation
import WovenMatterCore

extension ApplicationModel {
    @discardableResult
    func mutateConversationGoal(id: String, mutation: WorkspaceGoalMutation,
                                dispatchFence suppliedFence: AgentDispatchFence? = nil) async throws -> WorkspaceGoal? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        switch mutation {
        case let .set(objective, tokens, turns), let .edit(_, objective, tokens, turns):
            try WorkspaceGoal.validate(objective: objective, tokenBudget: tokens, turnBudget: turns)
        default: break
        }
        let starts: Bool
        switch mutation { case .set, .resume: starts = true; default: starts = false }
        let fence = starts ? suppliedFence ?? beginAgentDispatch(conversationID: id) : nil
        defer { if let fence, suppliedFence == nil { finishAgentDispatch(conversationID: id, fence: fence) } }
        if starts { try await waitForAgentStop(conversationID: id); try fence?.check() }
        if case .set = mutation { try await applyPendingSessionSelections(conversationID: id) }
        let stops: Bool
        switch mutation { case .pause, .clear, .edit: stops = true; default: stops = false }
        let result: Result<WorkspaceGoal?, any Error>
        if stops {
            let expectedID: String
            switch mutation {
            case .pause(let id), .clear(let id), .edit(let id, _, _, _): expectedID = id
            default: throw WorkspaceToolError.invalid("Unsupported goal control.")
            }
            guard let current = try await database.sessionGoals().first(where: { $0.sessionID == id }), current.id == expectedID else {
                throw WorkspaceToolError.invalid("This goal has changed. Refresh before updating it.")
            }
            if case .pause = mutation, current.status == .complete { throw WorkspaceToolError.invalid("This goal is complete. Set a new goal.") }

            // Install the barrier before any await, and keep the mutation inside
            // it so a later Resume or user input observes the whole operation.
            let outcome = GoalMutationOutcome()
            let barrier = beginAgentStop(conversationID: id, afterStop: {
                // Native Stop failures remain retained. A rejected goal change
                // reports its own error without blocking future conversation input.
                do { outcome.value = .success(try await database.mutateGoal(sessionID: id, mutation: mutation)) }
                catch { outcome.value = .failure(error) }
            })
            try await barrier.value
            result = outcome.value
        } else {
            try fence?.check()
            result = .success(try await database.mutateGoal(sessionID: id, mutation: mutation, dispatchFence: fence))
        }
        try await agentTools?.reload()
        await backendApplicationService?.invalidations.publish(scopes: [.settings], conversationIDs: [id])
        return try result.get()
    }

    private func blockGoalDelivery(_ delivery: WorkspaceSessionDelivery, reason: String) async {
        guard let database = dashboardStore?.database,
              let goal = try? await database.sessionGoals().first(where: { $0.sessionID == delivery.targetID }),
              goal.status == .active, goal.pendingDeliveryID == delivery.id else { return }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = clean.isEmpty ? "Goal dispatch failed." : String(clean.prefix(1_024))
        _ = try? await database.mutateGoal(sessionID: goal.sessionID,
            mutation: .block(id: goal.id, evidence: evidence))
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

@MainActor
private final class GoalMutationOutcome {
    var value: Result<WorkspaceGoal?, any Error> = .failure(CancellationError())
}
