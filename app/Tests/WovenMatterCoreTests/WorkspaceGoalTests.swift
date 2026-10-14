import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Persistent goals and safe continuation")
struct WorkspaceGoalTests {
    private func fixture(_ kind: AgentRuntimeKind = .defaultAgent) async throws -> (WorkspaceDatabase, URL, String) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await db.createLocalACPSession(runtimeKind: kind, title: "Goal test", ownerDeviceID: UUID())
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

    @Test(arguments: [AgentRuntimeKind.defaultAgent, .codex, .claudeCode, .grokBuild, .opencode])
    func allRemainingHarnessesPersistAndContinue(kind: AgentRuntimeKind) async throws {
        let (db, directory, session) = try await fixture(kind)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        #expect(try await reopened.sessionGoals().first == goal)
        #expect(try await reopened.dueGoalDeliveries(running: [session]).isEmpty)
        let first = try #require(await reopened.dueGoalDeliveries(running: []).first)
        #expect(first.kind == .goal && first.sourceID == session && first.targetID == session)
        #expect(first.text.contains(goal.id))
        let retry = try #require(await db.dueGoalDeliveries(running: []).first)
        #expect(retry.id == first.id)
        #expect(try await db.claimToolDelivery(id: first.id) != nil)
        #expect(try await reopened.claimToolDelivery(id: first.id) == nil)
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

    @Test func pauseClearDisableAndRestartCancelUnsentContinuations() async throws {
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
        #expect(try await db.sessionGoals().first?.status == .paused)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
    }

    @Test func stoppedPreparationCannotSetOrResumeAGoal() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fence = AgentDispatchFence()
        fence.cancel()
        await #expect(throws: CancellationError.self) {
            try await db.mutateGoal(sessionID: session,
                mutation: .set(objective: "Delayed goal", tokenBudget: nil, turnBudget: nil), dispatchFence: fence)
        }
        #expect(try await db.sessionGoals().isEmpty)
        let goal = try await create(db, session)
        _ = try await db.mutateGoal(sessionID: session, mutation: .pause(id: goal.id))
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = Task {
            try await db.write { _ in
                entered.continuation.yield(())
                release.wait()
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        let delayedFence = AgentDispatchFence()
        let delayedResume = Task {
            try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id), dispatchFence: delayedFence)
        }
        let deadline = Date().addingTimeInterval(5)
        while db.workerMetrics[0].pending < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(db.workerMetrics[0].pending == 2)
        delayedFence.cancel()
        release.signal()
        try await writer.value
        await #expect(throws: CancellationError.self) { try await delayedResume.value }
        #expect(try await db.sessionGoals().first?.status == .paused)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
    }

    @Test func verifiedCompletionAndProgressGovernContinuation() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "run-a")
        _ = try await db.mutateGoal(sessionID: session, mutation: .checkpoint(id: goal.id, evidence: "Fixed one failure; a second remains"))
        #expect(try await db.dueGoalDeliveries(running: []).count == 1)
        await #expect(throws: (any Error).self) {
            try await db.mutateGoal(sessionID: session, mutation: .complete(id: goal.id, evidence: " "))
        }
        _ = try await db.mutateGoal(sessionID: session, mutation: .complete(id: goal.id, evidence: "All fixture checks passed"))
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .complete)
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

    @Test func statusOnlyToolCallsAndRepeatedCheckpointsCannotKeepAGoalSpinning() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        _ = try await db.mutateGoal(sessionID: session, mutation: .checkpoint(id: goal.id, evidence: "Work remains"))
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "status-only-turn")
        try await db.write { connection in
            try connection.toolsExecuteUnlocked("INSERT INTO dashboard_run_events(id,run_id,event_type,content,created_at) VALUES(?,?,?,?,?)",
                ["goal-status-read", "status-only-turn", "tool", "wovenmatter goals get", WorkspaceDatabaseConnection.timestamp(Date())])
        }
        _ = try await db.mutateGoal(sessionID: session, mutation: .checkpoint(id: goal.id, evidence: "Work remains"))
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

    @Test func turnBudgetIncludesRunsFirstObservedAfterCompletion() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session, turns: 1)
        try await run(db, session: session, id: "completed-before-enrollment")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .budgetLimited)
        #expect(try await db.sessionGoals().first?.completedTurns == 1)
    }

    @Test func repeatedResumeRetainsPendingDeliveryAndStallDetection() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        _ = try await db.claimToolDelivery(id: delivery.id)
        try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        try await run(db, session: session, id: "resumed-active-turn", status: "running")
        let resumed = try #require(await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id)))
        #expect(resumed.pendingDeliveryID == delivery.id)
        #expect(resumed.observedRunSequence == goal.observedRunSequence)
        try await db.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='completed' WHERE id='resumed-active-turn'") }
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .blocked)
    }

    @Test func resumeDoesNotReobserveTheOldTurnStillSettlingAfterStop() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        try await run(db, session: session, id: "stopped-turn", status: "running")
        _ = try await db.mutateGoal(sessionID: session, mutation: .pause(id: goal.id))
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        try await db.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='cancelled' WHERE id='stopped-turn'") }
        #expect(try await db.dueGoalDeliveries(running: []).count == 1)
        #expect(try await db.sessionGoals().first?.status == .active)
    }

    @Test func conversationalResumeCountsItsTurnButExcludesEarlierPausedWork() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session, tokens: 100, turns: 1)
        _ = try await db.mutateGoal(sessionID: session, mutation: .pause(id: goal.id))
        try await run(db, session: session, id: "earlier-paused-work")
        try await db.recordGoalUsage(runID: "earlier-paused-work", tokens: 500)
        try await run(db, session: session, id: "conversational-resume", status: "running")
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        try await db.recordGoalUsage(runID: "conversational-resume", tokens: 40)
        try await db.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='completed' WHERE id='conversational-resume'") }
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        let saved = try #require(await db.sessionGoals().first)
        #expect(saved.tokensUsed == 40 && saved.completedTurns == 1 && saved.status == .budgetLimited)
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

    @Test func queuedInputAndActiveNativeRunsTakePrecedence() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session)
        try await run(db, session: session, id: "active", status: "running")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        try await db.write { connection in try connection.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='completed' WHERE id='active'") }
        let source = try await db.createLocalACPSession(runtimeKind: .codex, title: "User input", ownerDeviceID: UUID())
        _ = try await db.reserveToolDelivery(sourceID: source, targetID: session, text: "New input", requestID: UUID().uuidString)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
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

    @Test func lateUsageBelongsToTheStoppedGoalAndPausedWorkIsExcluded() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        try await run(db, session: session, id: "goal-root", status: "running")
        _ = try await db.mutateGoal(sessionID: session, mutation: .pause(id: goal.id))
        try await db.recordGoalUsage(runID: "goal-root", tokens: 40)
        try await run(db, session: session, id: "ordinary-paused-turn")
        try await db.recordGoalUsage(runID: "ordinary-paused-turn", tokens: 500)
        #expect(try await db.sessionGoals().first?.tokensUsed == 40)
        _ = try await db.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
        try await db.recordGoalUsage(runID: "ordinary-paused-turn", tokens: 500)
        try await db.recordGoalUsage(runID: "goal-root", tokens: 60)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
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
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
        snapshot.active = false
        snapshot.permissions = [.object(["id": .string("approval")])]
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: session)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.tokensUsed == 60)
    }

    @Test func planOnlyWorkPausesGoalsAndDisablingIsNotReenabledOnReopen() async throws {
        let (db, directory, session) = try await fixture(.claudeCode)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await create(db, session)
        try await db.updateLocalACPSessionConfiguration(conversationID: session, model: nil, thinking: nil, permission: "plan")
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await db.sessionGoals().first?.status == .paused)
        _ = try await db.setSessionToolEnabled(.goals, enabled: false, sessionID: session)
        let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        #expect(try await reopened.sessionTools(session).enabled.contains(.goals) == false)
    }

    @Test func trashRestoreCannotRestartAGoalAndClearCleansItsAccounting() async throws {
        let (db, directory, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = try await create(db, session)
        try await run(db, session: session, id: "retained-goal-run")
        try await db.recordGoalUsage(runID: "retained-goal-run", tokens: 50)
        let delivery = try #require(await db.dueGoalDeliveries(running: []).first)
        try await db.mutateConversation(id: session, mutation: .moveToTrash)
        try await db.mutateConversation(id: session, mutation: .restore)
        #expect(try await db.sessionGoals().first?.status == .paused)
        #expect(try await db.claimToolDelivery(id: delivery.id) == nil)
        #expect(try await db.dueGoalDeliveries(running: []).isEmpty)
        _ = try await db.mutateGoal(sessionID: session, mutation: .clear(id: goal.id))
        #expect(try await db.sessionGoals().isEmpty)
        let retained = try await db.read { connection in
            try connection.historyRowsUnlocked("SELECT count(*) AS count FROM workspace_goal_runs WHERE goal_id=?", values: [goal.id]).first?.objectValue?["count"]?.intValue ?? -1
        }
        #expect(retained == 0)
    }

    @Test func slashAndCLICommandsValidateLifecycleAndScope() throws {
        #expect(WorkspaceGoalCommand(" /goal Fix the flaky test ") == .set("Fix the flaky test"))
        #expect(WorkspaceGoalCommand("/goal resume") == .resume)
        #expect(WorkspaceGoalCommand("/goals") == nil)
        #expect(WorkspaceGoalCommand("Please set /goal") == nil)
        #expect(try WovenMatterToolCommand(["goals", "get"]).isMutation == false)
        #expect(try WovenMatterToolCommand(["goals", "set", "--objective", "Pass checks"]).isMutation)
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["goals", "complete", "--session", "other"]) }
        #expect(throws: (any Error).self) { try WorkspaceGoal.validate(objective: "", tokenBudget: nil, turnBudget: nil) }
        #expect(throws: (any Error).self) { try WorkspaceGoal.validate(objective: "Result", tokenBudget: 0, turnBudget: nil) }
    }
}
