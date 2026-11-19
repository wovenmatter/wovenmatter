import Foundation
import Testing
@testable import WovenMatterShared

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
        // A run that reports a checkpoint keeps the goal active, and settles once.
        let runID = UUID().uuidString
        ledger.enroll(runID)
        _ = try ledger.mutate(.checkpoint(id: first.id, evidence: "Fixed a verified defect"))
        ledger.settle(runID, tokens: 42, succeeded: true)
        ledger.settle(runID, tokens: 42, succeeded: true)
        #expect(ledger.goal?.completedTurns == 1)
        #expect(ledger.goal?.tokensUsed == 42)
        #expect(ledger.goal?.status == .active)
        let second = UUID().uuidString
        ledger.enroll(second)
        ledger.settle(second, tokens: 11, succeeded: true)
        #expect(ledger.goal?.completedTurns == 2)
        #expect(ledger.goal?.tokensUsed == 53)
        // A run of a new goal that ends without a checkpoint blocks it.
        var unreported = WorkspaceGoalLedger()
        _ = try unreported.mutate(.set(objective: "Verify the change", tokenBudget: nil, turnBudget: nil))
        let silent = UUID().uuidString
        unreported.enroll(silent)
        unreported.settle(silent, tokens: nil, succeeded: true)
        #expect(unreported.goal?.status == .blocked)
        // A run that fails blocks it too, and a run the ledger never enrolled changes nothing.
        ledger.settle(UUID().uuidString, tokens: 7, succeeded: false)
        #expect(ledger.goal?.status == .active && ledger.goal?.tokensUsed == 53)
        let failed = UUID().uuidString
        ledger.enroll(failed)
        ledger.settle(failed, tokens: 1, succeeded: false)
        #expect(ledger.goal?.status == .blocked)
    }

    @Test func stopRecoveryAndEditFencePendingWork() throws {
        var ledger = WorkspaceGoalLedger()
        let goalResult = try ledger.mutate(.set(objective: "Finish", tokenBudget: nil, turnBudget: nil))
        let goal = try #require(goalResult)
        _ = try ledger.mutate(.pause(id: goal.id))
        #expect(ledger.goal?.status == .paused)
        // A run of a paused goal is not the goal's.
        let paused = UUID().uuidString
        ledger.enroll(paused)
        #expect(!ledger.runIDs.contains(paused))
        _ = try ledger.mutate(.resume(id: goal.id))
        #expect(ledger.goal?.status == .active)
        ledger.recover()
        #expect(ledger.goal?.status == .paused)
        let editedResult = try ledger.mutate(.edit(id: goal.id, objective: "New outcome", tokenBudget: nil, turnBudget: nil))
        let edited = try #require(editedResult)
        #expect(edited.id != goal.id && edited.status == .paused)
        #expect(throws: WorkspaceToolError.self) { try ledger.mutate(.resume(id: goal.id)) }
        let persisted = try JSONDecoder().decode(WorkspaceGoalLedger.self, from: JSONEncoder().encode(ledger))
        #expect(persisted == ledger)
    }
}
