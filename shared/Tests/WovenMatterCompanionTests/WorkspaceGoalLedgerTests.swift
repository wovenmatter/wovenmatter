import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite struct WorkspaceGoalLedgerTests {
    @Test func durableReceiptAndCheckpointGate() throws {
        var ledger = WorkspaceGoalLedger()
        let requestID = UUID().uuidString, sessionID = UUID().uuidString
        let mutation = WorkspaceGoalMutation.set(objective: "Verify the change", tokenBudget: nil, turnBudget: 3)
        let firstResult = try ledger.mutate(mutation, requestID: requestID, sessionID: sessionID)
        let first = try #require(firstResult)
        #expect(first.sessionID == sessionID)
        #expect(try ledger.mutate(mutation, requestID: requestID, sessionID: sessionID) == first)
        #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.clear(id: first.id), requestID: requestID) }
        let runID = UUID().uuidString
        #expect(ledger.claimContinuation(id: runID) != nil)
        #expect(ledger.authorizes(runID))
        ledger.enroll(runID)
        #expect(ledger.claimContinuation(id: UUID().uuidString) == nil)
        _ = try ledger.mutate(.checkpoint(id: first.id, evidence: "Fixed a verified defect"))
        ledger.settle(runID, tokens: 42, succeeded: true)
        ledger.settle(runID, tokens: 42, succeeded: true)
        #expect(ledger.goal?.completedTurns == 1)
        #expect(ledger.goal?.tokensUsed == 42)
        #expect(ledger.goal?.status == .active)
        let second = UUID().uuidString
        #expect(ledger.claimContinuation(id: second) != nil)
        ledger.enroll(second)
        _ = try ledger.mutate(.checkpoint(id: first.id, evidence: "Fixed a verified defect"))
        ledger.settle(second, tokens: 11, succeeded: true)
        #expect(ledger.goal?.status == .blocked)
        #expect(ledger.goal?.tokensUsed == 53)
    }
    @Test func stopRecoveryAndEditFencePendingWork() throws {
        var ledger = WorkspaceGoalLedger()
        let goalResult = try ledger.mutate(.set(objective: "Finish", tokenBudget: nil, turnBudget: nil))
        let goal = try #require(goalResult)
        let delivery = UUID().uuidString
        _ = ledger.claimContinuation(id: delivery)
        _ = try ledger.mutate(.pause(id: goal.id))
        #expect(!ledger.authorizes(delivery))
        _ = try ledger.mutate(.resume(id: goal.id))
        let next = UUID().uuidString
        #expect(ledger.claimContinuation(id: next) != nil)
        ledger.recover()
        #expect(!ledger.authorizes(next))
        #expect(ledger.goal?.status == .paused)
        let editedResult = try ledger.mutate(.edit(id: goal.id, objective: "New outcome", tokenBudget: nil, turnBudget: nil))
        let edited = try #require(editedResult)
        #expect(edited.id != goal.id && edited.status == .paused)
        #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.resume(id: goal.id)) }
        let persisted = try JSONDecoder().decode(WorkspaceGoalLedger.self, from: JSONEncoder().encode(ledger))
        #expect(persisted == ledger)
    }
    @Test func budgetAndMissingUsageStopContinuation() throws {
        for missing in [false, true] {
            var ledger = WorkspaceGoalLedger()
            let goalResult = try ledger.mutate(.set(objective: "Finish", tokenBudget: 10, turnBudget: nil), currentRunID: "run")
            let goal = try #require(goalResult)
            _ = try ledger.mutate(.checkpoint(id: goal.id, evidence: "Useful progress"))
            ledger.settle("run", tokens: missing ? nil : 10, succeeded: true)
            #expect(ledger.goal?.status == (missing ? .blocked : .budgetLimited))
            #expect(ledger.claimContinuation(id: "next") == nil)
            if !missing { #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.resume(id: goal.id)) } }
        }
    }
    @Test func missingUsageCannotBeBypassedByResumeOrAnEditedBudget() throws {
        var ledger = WorkspaceGoalLedger()
        let created = try ledger.mutate(.set(objective: "Finish", tokenBudget: 100, turnBudget: nil), currentRunID: "run")
        let goal = try #require(created)
        ledger.settle("run", tokens: nil, succeeded: true)
        #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.resume(id: goal.id)) }
        let edited = try ledger.mutate(.edit(id: goal.id, objective: "Finish", tokenBudget: 200, turnBudget: nil))
        #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.resume(id: edited!.id)) }
        let unbudgeted = try ledger.mutate(.edit(id: edited!.id, objective: "Finish", tokenBudget: nil, turnBudget: nil))
        _ = try ledger.mutate(.resume(id: unbudgeted!.id))
        #expect(ledger.claimContinuation(id: "next") != nil)
    }

    @Test func noCheckpointAndFailedRunCannotSpin() throws {
        for succeeded in [false, true] {
            var ledger = WorkspaceGoalLedger()
            _ = try ledger.mutate(.set(objective: "Finish", tokenBudget: nil, turnBudget: nil), currentRunID: "run")
            ledger.settle("run", tokens: nil, succeeded: succeeded)
            #expect(ledger.goal?.status == .blocked)
            #expect(ledger.goal?.completedTurns == (succeeded ? 1 : 0))
            #expect(ledger.claimContinuation(id: "next") == nil)
        }
    }
    @Test func guidanceIsHiddenOnlyInDisplayProjection() {
        let prompt = "Original message" + WorkspaceGoal.guidance
        #expect(WorkspaceGoal.displayPrompt(prompt) == "Original message")
        let goal = WorkspaceGoal(sessionID: "session", objective: "Verify")
        #expect(WorkspaceGoal.displayPrompt(goal.continuationPrompt + WorkspaceGoal.guidance) == "Continuing toward the goal.")
        #expect(WorkspaceGoal.displayPrompt("User mentions <wovenmatter-goals>") == "User mentions <wovenmatter-goals>")
    }
    @Test func ownerGoalContractRoundTripsAndOlderSettingsRemainReadable() throws {
        let goal = WorkspaceGoal(sessionID: "session", objective: "Verify")
        let settings = CompanionSessionSettings(conversationID: "session", model: nil, thinking: nil, permission: nil, models: [], thinkingLevels: [], permissions: [], availableTools: [], enabledTools: [], canConfigure: true, goal: goal)
        #expect(try JSONDecoder().decode(CompanionSessionSettings.self, from: JSONEncoder().encode(settings)).goal == goal)
        let action = CompanionWorkspaceAction.goal(id: "session", mutation: .pause(id: goal.id))
        #expect(try JSONDecoder().decode(CompanionWorkspaceAction.self, from: JSONEncoder().encode(action)) == action)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]); object.removeValue(forKey: "goal")
        #expect(try JSONDecoder().decode(CompanionSessionSettings.self, from: JSONSerialization.data(withJSONObject: object)).goal == nil)
    }
}
