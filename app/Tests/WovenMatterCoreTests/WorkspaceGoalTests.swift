import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Persistent goals and safe continuation")
struct WorkspaceGoalTests {

    @Test func openCodeNativeWorkAndQuestionsPreventContinuationAndUsageIsCaptured() async throws {
        let (db, persistence, session) = try await fixture(.opencode)
        defer { persistence.remove() }
        _ = try await create(db, session, tokens: 100)
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

    private func fixture(_ kind: AgentRuntimeKind = .defaultAgent) async throws -> (WorkspaceDatabase, PersistenceFixture, String) {
        let persistence = try PersistenceFixture()
        let db = try await persistence.openDatabase()
        let id = try await db.createFixtureLocalACPSession(runtimeKind: kind, title: "Goal test", ownerDeviceID: UUID(),
            openCodeAssociation: kind == .opencode ? ("fixture", "native") : nil,
            fixtureLocation: .init(workspaceID: "local", rootPath: persistence.directory.path, managed: false))
        return (db, persistence, id)
    }

    private func create(_ db: WorkspaceDatabase, _ session: String, tokens: Int64? = nil, turns: Int? = nil) async throws -> WorkspaceGoal {
        try #require(await db.mutateGoal(sessionID: session,
            mutation: .set(objective: "Make the fixture pass and verify it", tokenBudget: tokens, turnBudget: turns)))
    }

    private func run(_ db: WorkspaceDatabase, session: String, id: String, status: String = "completed") async throws {
        try await db.write { connection in
            try connection.toolsExecuteUnlocked("INSERT INTO runs(id,conversation_id,status,created_at) VALUES(?,?,?,?)",
                [id, session, status, WorkspaceDatabaseConnection.timestamp(Date())])
        }
    }

    @Test func noProgressAndUncertainDeliveryNeverSpinOrReplay() async throws {
        let (db, persistence, session) = try await fixture()
        defer { persistence.remove() }
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


}
