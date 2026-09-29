import Foundation
import Testing
import WovenMatterCore

@Suite("Causal frontend Stop admission")
struct AgentDispatchAdmissionTests {
    private let instance = UUID()
    private let clientA = UUID()
    private let clientB = UUID()
    private func frame(_ client: UUID, _ sequence: UInt64, _ revision: UInt64 = 0) -> AgentDispatchAdmission {
        .init(instanceID: instance, clientID: client, stopSequence: sequence, observedStopRevision: revision)
    }

    @Test func delayedOldSendIsRejectedAfterStop() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        let old = frame(clientA, 0)
        #expect(try !ledger.prepareSend(old, conversationID: "session"))
        #expect(try ledger.prepareStop(frame(clientA, 1), conversationID: "session"))
        #expect(throws: AgentDispatchAdmissionError.stopped) { try ledger.validateSend(old, conversationID: "session") }
        #expect(throws: AgentDispatchAdmissionError.stopped) { try ledger.prepareSend(old, conversationID: "session") }
    }

    @Test func newerSendCarriesStopAndLateEqualStopDoesNotCancelIt() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        let next = frame(clientA, 1)
        #expect(try ledger.prepareSend(next, conversationID: "session"))
        #expect(try !ledger.prepareStop(next, conversationID: "session"))
        try ledger.validateSend(next, conversationID: "session")
        #expect(ledger.stopRevisions["session"] == 1)
        #expect(try !ledger.prepareSend(next, conversationID: "session"))
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

    @Test func legacyStopInvalidatesOldInputButCurrentObservationCanRetry() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        _ = try ledger.prepareSend(frame(clientA, 0), conversationID: "session")
        try ledger.prepareLegacyStop(conversationID: "session")
        #expect(throws: AgentDispatchAdmissionError.stopped) { try ledger.validateSend(frame(clientA, 0), conversationID: "session") }
        _ = try ledger.prepareSend(frame(clientA, 0, 1), conversationID: "session")
        try ledger.validateSend(frame(clientA, 0, 1), conversationID: "session")
    }

    @Test func oldBackendLifetimeCannotSendOrStopNewWork() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: UUID())
        #expect(throws: AgentDispatchAdmissionError.restarted) { try ledger.prepareSend(frame(clientA, 0), conversationID: "session") }
        #expect(throws: AgentDispatchAdmissionError.restarted) { try ledger.prepareStop(frame(clientA, 1), conversationID: "session") }
        #expect(ledger.stopRevisions.isEmpty)
    }

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

    @Test func identifiersMatchExactBackendLookupRatherThanCaseFoldAliases() throws {
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        _ = try ledger.prepareSend(frame(clientA, 0), conversationID: "Session")
        _ = try ledger.prepareStop(frame(clientA, 1), conversationID: "session")
        try ledger.validateSend(frame(clientA, 0), conversationID: "Session")
        #expect(ledger.stopRevisions["session"] == 1)
        #expect(ledger.stopRevisions["Session"] == 0)
    }
}

@Suite("Native Stop barriers", .serialized)
@MainActor
struct AgentStopCoordinatorTests {
    private enum Failure: Error { case stop }

    @Test func newInputWaitsForStopThenRevalidatesAgainstAnotherStop() async throws {
        let coordinator = AgentStopCoordinator()
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let instance = UUID(), client = UUID()
        var ledger = AgentDispatchAdmissionLedger(instanceID: instance)
        let input = AgentDispatchAdmission(instanceID: instance, clientID: client, stopSequence: 1, observedStopRevision: 0)
        _ = try ledger.prepareSend(input, conversationID: "session")
        let stop = coordinator.begin(conversationID: "session") {
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        var resumed = false
        let waiting = Task {
            try await coordinator.wait(conversationID: "session")
            resumed = true
        }
        await Task.yield()
        #expect(!resumed)
        _ = try ledger.prepareStop(.init(instanceID: instance, clientID: client, stopSequence: 2, observedStopRevision: 1), conversationID: "session")
        release.continuation.yield(())
        try await stop.value
        try await waiting.value
        #expect(resumed)
        #expect(throws: AgentDispatchAdmissionError.stopped) { try ledger.validateSend(input, conversationID: "session") }
    }

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

    @Test func secondStopWaitsForFirstAndSupersededCleanupCannotReleaseNewBarrier() async throws {
        let coordinator = AgentStopCoordinator()
        let firstRelease = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        var order: [Int] = []
        let first = coordinator.begin(conversationID: "session") {
            order.append(1)
            for await _ in firstRelease.stream { break }
        }
        let second = coordinator.begin(conversationID: "session") {
            order.append(2)
            secondStarted.continuation.yield(())
            for await _ in secondRelease.stream { break }
        }
        firstRelease.continuation.yield(())
        try await first.value
        var started = secondStarted.stream.makeAsyncIterator()
        await started.next()
        var admitted = false
        let input = Task { try await coordinator.wait(conversationID: "session"); admitted = true }
        await Task.yield()
        #expect(!admitted)
        #expect(order == [1, 2])
        secondRelease.continuation.yield(())
        try await second.value
        try await input.value
        #expect(admitted)
    }
}
