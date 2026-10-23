import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Persistent goals and safe continuation")
struct WorkspaceGoalTests {



    @Test func incompleteOpenCodeUsageDoesNotBecomeZeroTokens() async throws {
        let (db, directory, session) = try await fixture(.opencode)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session, tokens: 100)
        try await db.attachOpenCodeSession(.init(conversationID: session, connectionID: "fixture", sessionID: "native"))
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.messages = [.object(["id": .string("assistant"), "type": .string("assistant"),
            "time": .object(["created": .number(1000), "completed": .number(2000)]),
            "content": .array([.object(["type": .string("step-finish"), "tokens": .object([:])])])])]
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: session)
        #expect(try await db.sessionGoals().first?.tokensUsed == nil)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .blocked)
    }

    @Test func openCodeNativeWorkAndQuestionsPreventContinuationAndUsageIsCaptured() async throws {
        let (db, directory, session) = try await fixture(.opencode)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session, tokens: 100)
        try await db.attachOpenCodeSession(.init(conversationID: session, connectionID: "fixture", sessionID: "native"))
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.active = true
        snapshot.messages = [.object(["id": .string("assistant"), "type": .string("assistant"),
            "time": .object(["created": .number(1000), "completed": .number(2000)]),
            "content": .array([.object(["type": .string("step-finish"), "tokens": .object(["input": .number(40), "output": .number(20)])])])])]
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: session)
        #expect(try await db.conversationContent(id: session).runs.allSatisfy { $0.status == "completed" })
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
        snapshot.active = false
        snapshot.permissions = [.object(["id": .string("approval")])]
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: session)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
        #expect(try await db.sessionGoals().first?.status == .active)
        // Clearing the native blocker admits work with the same complete accounting.
        snapshot.permissions = []
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: session)
        #expect(try await db.dueGoalDeliveries(running: []).count == 1)
    }

    @Test func planModePausesAutomaticGoalContinuation() async throws {
        let (db, directory, session) = try await fixture(.claudeCode)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session)
        let pending = try #require(await db.dueGoalDeliveries(running: []).first)
        try await db.updateLocalACPSessionConfiguration(conversationID: session, model: nil, thinking: nil, permission: "plan")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .paused)
        #expect(try await db.claimToolDelivery(id: pending.id) == nil)
    }

    private func fixture(_ kind: AgentRuntimeKind = .defaultAgent) async throws -> (WorkspaceDatabase, URL, String) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await db.createLocalACPSession(runtimeKind: kind, title: "Goal test", ownerDeviceID: UUID(),
            executionRoot: .init(folderID: nil, location: .init(workspaceID: "local", rootPath: directory.path, managed: false), defaultPath: directory.path))
        return (db, directory, id)
    }

    private func create(_ db: WorkspaceDatabase, _ session: String, tokens: Int64? = nil, turns: Int? = nil) async throws -> WorkspaceGoal {
        try #require(await db.mutateGoal(sessionID: session,
            mutation: .set(objective: "Make the fixture pass and verify it", tokenBudget: tokens, turnBudget: turns)))
    }

    private func run(_ db: WorkspaceDatabase, session: String, id: String, status: String = "completed") async throws {
        try await db.write { connection in
            try connection.toolsExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,created_at) VALUES(?,?,?,?)",
                [id, session, status, WorkspaceDatabaseConnection.timestamp(Date())])
        }
    }

    @Test func ownershipTransferPausesAndFencesThePreviousOwner() async throws {
        let (db, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try await db.companionLibraryIdentity(), workspaceID = UUID()
        let owner = CompanionExecutionWorkspace(id: workspaceID.uuidString.lowercased(), libraryID: identity.libraryID,
            ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Independent Linux")
        _ = try await db.registerCompanionExecutionWorkspace(.init(workspace: owner), deviceID: identity.hostDeviceID)
        let session = try await db.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: workspaceID,
            remoteWorkspaceName: owner.name, title: "Transferred goal", ownerDeviceID: UUID(),
            executionRoot: .init(folderID: nil, location: .init(workspaceID: "remote:" + owner.id, rootPath: directory.path, managed: false), defaultPath: "/workspace"))
        try await db.write { try $0.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET acp_session_id='native-fixture' WHERE conversation_id=?", [session]) }
        let goal = try await create(db, session)
        let delivery = try #require(try await db.dueGoalDeliveries(running: []).first)
        #expect(try await db.claimToolDelivery(id: delivery.id) != nil)
        let adoption = try await db.prepareCompanionExecutionAdoption(conversationID: session, workspaceID: owner.id, deviceID: identity.hostDeviceID)
        #expect(adoption.goal?.id == goal.id && adoption.goal?.status == .paused)
        #expect(adoption.goal?.pendingDeliveryID == nil)
        #expect(try await db.toolDelivery(id: delivery.id)?.status == "cancelled")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: delivery.id) }
        await #expect(throws: (any Error).self) { try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id)) }
        let retry = try await db.prepareCompanionExecutionAdoption(conversationID: session, workspaceID: owner.id, deviceID: identity.hostDeviceID)
        #expect(retry == adoption)
    }

    @Test func mutationRetriesCannotReplaceANewerGoalOrTargetAnotherSession() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = UUID().uuidString
        let mutation = WorkspaceGoalMutation.set(objective: "Verified result", tokenBudget: nil, turnBudget: nil)
        let first = try #require(await db.mutateGoal(sessionID: session, mutation: mutation, callerID: session, requestID: request))
        let duplicate = try #require(await db.mutateGoal(sessionID: session, mutation: mutation, callerID: session, requestID: request))
        #expect(first.id == duplicate.id)
        try await run(db, session: session, id: "achieved-goal-run")
        try await db.recordGoalUsage(runID: "achieved-goal-run", tokens: 50)
        _ = try await db.mutateGoal(sessionID: session, mutation: .complete(id: first.id, evidence: "Fixture passed"))
        let replacement = try await create(db, session)
        #expect(replacement.tokensUsed == nil && replacement.completedTurns == 0)
        let retained = try await db.read { connection in
            try connection.historyRowsUnlocked("SELECT 1 FROM workspace_goal_runs WHERE goal_id=? UNION ALL SELECT 1 FROM workspace_goal_usage WHERE goal_id=?", values: [first.id, first.id])
        }
        #expect(retained.isEmpty)
        await #expect(throws: (any Error).self) {
            try await db.mutateGoal(sessionID: session, mutation: .clear(id: first.id))
        }
        #expect(try await db.sessionGoals().first?.id == replacement.id)
        await #expect(throws: (any Error).self) {
            try await db.mutateGoal(sessionID: session, mutation: .pause(id: replacement.id), callerID: "other")
        }
    }

    @Test func pauseAndRestartCancelUnsentContinuationsButToolSelectionDoesNot() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.mutateGoal(sessionID: session, mutation: .pause(id: goal.id))
        #expect(try await db.claimToolDelivery(id: delivery.id) == nil)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        let resumed = try #require(await db.dueGoalDeliveries(running: []).first)
        #expect(resumed.id != delivery.id)
        try await db.pauseActiveGoals(reason: "Owner restarted")
        #expect(try await db.sessionGoals().first?.status == .paused)
        #expect(try await db.claimToolDelivery(id: resumed.id) == nil)
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        _ = try await db.setSessionToolEnabled(.goals, enabled: false, sessionID: session)
        #expect(try await db.sessionGoals().first?.status == .active)
        #expect(try await db.dueGoalDeliveries(running: []).count == 1)
    }

    @Test func noProgressAndUncertainDeliveryNeverSpinOrReplay() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "empty-turn")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .blocked)
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        let next = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: next.id)
        try await db.markToolDeliveryTransportStarted(id: next.id)
        try await db.recoverToolDeliveries()
        #expect(try await db.toolDelivery(id: next.id)?.status == "uncertain")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .blocked)
    }

    @Test func usageIsIdempotentAndBudgetExhaustionIsNotCompletion() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session, tokens: 100)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "budget-turn")
        try await db.recordGoalUsage(runID: "budget-turn", tokens: 60)
        try await db.recordGoalUsage(runID: "budget-turn", tokens: 60)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
        try await db.recordGoalUsage(runID: "budget-turn", tokens: 110)
        _ = try await db.mutateGoal(sessionID: session, mutation: .checkpoint(id: goal.id, evidence: "Useful progress; work remains"))
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .budgetLimited)
        #expect(try await db.sessionGoals().first?.tokensUsed == 110)
        await #expect(throws: (any Error).self) { try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id)) }
    }

    @Test func aLaterTurnWithoutUsageCannotSilentlyBypassTheTokenBudget() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session, tokens: 100)
        try await run(db, session: session, id: "reported-turn")
        try await db.recordGoalUsage(runID: "reported-turn", tokens: 40)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "unreported-turn")
        _ = try await db.mutateGoal(sessionID: session, mutation: .checkpoint(id: goal.id, evidence: "Progress with missing usage"))
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .blocked)
        #expect(try await db.sessionGoals().first?.tokensUsed == 40)
    }

    @Test func editingFencesTheOldObjectiveAndKeepsItsAccounting() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await create(db, session)
        try await run(db, session: session, id: "before-edit")
        try await db.recordGoalUsage(runID: "before-edit", tokens: 50)
        let edited = try #require(await db.mutateGoal(sessionID: session,
            mutation: .edit(id: original.id, objective: "A revised outcome", tokenBudget: 200, turnBudget: nil)))
        #expect(edited.id != original.id && edited.tokensUsed == 50 && edited.status == .paused)
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: edited.id))
        await #expect(throws: (any Error).self) {
            try await db.mutateGoal(sessionID: session, mutation: .complete(id: original.id, evidence: "Old result"))
        }
        try await db.recordGoalUsage(runID: "before-edit", tokens: 80)
        #expect(try await db.sessionGoals().first?.tokensUsed == 80)
    }

}
