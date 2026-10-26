import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Persistent goals and safe continuation")
struct WorkspaceGoalTests {

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
