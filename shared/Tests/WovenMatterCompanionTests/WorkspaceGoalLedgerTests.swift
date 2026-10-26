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
}
