import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BackendTranscriptInvalidationTests {
    @Test func replacedConsumerDoesNotReportALateTransportFailure() async throws {
        var receiveStarted = false
        var release: CheckedContinuation<BackendInvalidations, any Error>?
        var failed = false
        let consumer = Task {
            await BackendInvalidationConsumer.run(receive: { _ in
                receiveStarted = true
                return try await withCheckedThrowingContinuation { release = $0 }
            }, apply: { _ in Issue.record("Cancelled consumer applied state") },
                failed: { _ in failed = true })
        }
        try await waitUntil { receiveStarted }
        consumer.cancel()
        release?.resume(throwing: BackendRPCError.unavailable)
        await consumer.value
        #expect(!failed, "An old connection overwrote the replacement's status")
    }

    @Test func savedPromptAndStreamingAnswerRefreshWhileMetadataIsBlocked() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .grokBuild,
            title: "Invalidation fixture", ownerDeviceID: UUID())
        await fixture.model.refreshConversation(id: id)
        let state = try #require(fixture.model.conversationState(for: id))
        let journal = BackendInvalidationJournal(capacity: 2)
        var metadataStarted = false
        var releaseMetadata: CheckedContinuation<Void, Never>?
        let metadata = Task {
            await BackendInvalidationConsumer.run(receive: { cursor in
                await journal.waitForChanges(after: cursor)
            }, apply: { _ in
                metadataStarted = true
                await withCheckedContinuation { releaseMetadata = $0 }
            }, failed: { _ in Issue.record("Unexpected metadata failure") })
        }
        var refreshedIDs: [String] = []
        let transcript = Task {
            await BackendInvalidationConsumer.run(receive: { cursor in
                await journal.waitForChanges(after: cursor)
            }, apply: { change in
                let visible: Set<String> = [id]
                for affected in change.requiresReload ? visible : change.conversationIDs.intersection(visible) {
                    refreshedIDs.append(affected)
                    await fixture.model.refreshConversation(id: affected)
                }
            }, failed: { _ in Issue.record("Unexpected transcript failure") })
        }
        defer {
            metadata.cancel()
            transcript.cancel()
            releaseMetadata?.resume()
        }
        try await waitUntil { metadataStarted && !refreshedIDs.isEmpty }
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, content: "Visible fixture prompt")
        await journal.publish(scopes: [.settings, .usage], conversationIDs: [id, "unobserved-session"])
        try await waitUntil { state.content?.messages.contains { $0.role == "user" && $0.content == "Visible fixture prompt" } == true }
        #expect(releaseMetadata != nil, "The metadata gate must still be closed when the prompt appears")
        try await fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "First visible response.\n\n")
        await journal.publish(conversationIDs: [id])
        try await waitUntil { state.messagePresentations[run.assistantMessageID]?.displayedBody == "First visible response.\n\n" }
        #expect(Set(refreshedIDs) == [id], "An unobserved chat was read by the transcript consumer")

        // Terminal invalidation refreshes the same canonical IDs, without
        // resending a prompt or waiting for ancillary account inventory.
        try await fixture.database.completeLocalACPRun(runID: run.runID)
        await journal.publish(scopes: [.runtime], conversationIDs: [id])
        try await waitUntil { state.content?.runs.first?.status == "completed" }
        #expect(state.content?.messages.filter { $0.role == "user" }.count == 1)
        #expect(await fixture.recorder.deliveries.isEmpty)
        transcript.cancel()
        await transcript.value
        let count = refreshedIDs.count
        await journal.publish(conversationIDs: [id])
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshedIDs.count == count, "A cancelled consumer continued applying transcript updates")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Transcript refresh waited for the deliberately blocked metadata consumer")
    }
}
