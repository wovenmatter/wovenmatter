import Foundation
import Testing
import WovenMatterCore

@Suite("Causal frontend Stop admission")
struct AgentDispatchAdmissionTests {

    @Test func capacityNeverEvictsStopHistoryAndFailedStopPoisonsKnownConversation() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance, capacity: 1)
        _ = try ledger.prepareStop(frame(clientA, 1), conversationID: "session")
        #expect(throws: AgentDispatchAdmissionError.capacity) { try ledger.prepareSend(frame(clientB, 0), conversationID: "other") }
        #expect(throws: AgentDispatchAdmissionError.stopped) { try ledger.prepareSend(frame(clientA, 0), conversationID: "session") }
        #expect(throws: AgentDispatchAdmissionError.capacity) { try ledger.prepareStop(frame(clientB, 1), conversationID: "session") }
        ledger.refuseFurtherSends(conversationID: "session")
        #expect(throws: AgentDispatchAdmissionError.capacity) { try ledger.validateSend(frame(clientA, 1, UInt64.max), conversationID: "session") }
        #expect(ledger.stopRevisions.count == 1)
    }

    private let instance = UUID()
    private let clientA = UUID()
    private let clientB = UUID()
    private func frame(_ client: UUID, _ sequence: UInt64, _ revision: UInt64 = 0) -> AgentDispatchAdmission {
        .init(instanceID: instance, clientID: client, stopSequence: sequence, observedStopRevision: revision)
    }

    @Test func higherLocalSequenceCannotOverrideAnotherClientsUnseenStop() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        _ = try ledger.prepareSend(frame(clientA, 0), conversationID: "session")
        _ = try ledger.prepareStop(frame(clientB, 1), conversationID: "session")
        #expect(throws: AgentDispatchAdmissionError.stopped) {
            try ledger.prepareSend(frame(clientA, 1, 0), conversationID: "session")
        }
        #expect(ledger.stopRevisions["session"] == 1)
        #expect(try ledger.prepareSend(frame(clientA, 1, 1), conversationID: "session"))
        try ledger.validateSend(frame(clientA, 1, 1), conversationID: "session")
        #expect(throws: AgentDispatchAdmissionError.stopped) {
            try ledger.validateSend(frame(clientB, 1, 0), conversationID: "session")
        }
    }

}

@Suite("Native Stop barriers", .serialized)
@MainActor
struct AgentStopCoordinatorTests {
    private enum Failure: Error { case stop }

    @Test func failedStopBlocksEveryInputUntilExplicitRetryCompletes() async throws {
        let coordinator = AgentStopCoordinator()
        let stop = coordinator.begin(conversationID: "session") { throw Failure.stop }
        do { try await stop.value; Issue.record("Expected native Stop failure") } catch is Failure {}
        for _ in 0..<2 {
            do { try await coordinator.wait(conversationID: "session"); Issue.record("Failed Stop must block input") } catch is Failure {}
        }
        let retry = coordinator.begin(conversationID: "session") {}
        try await retry.value
        try await coordinator.wait(conversationID: "session")
        try await coordinator.wait(conversationID: "another-session")
    }

}
