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

}
