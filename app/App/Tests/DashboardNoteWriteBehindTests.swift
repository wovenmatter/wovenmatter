import Foundation
import Testing
import WovenMatterCore

@Suite("Async note write-behind")
struct DashboardNoteWriteBehindTests {
    private actor Writes {
        var values: [String] = []
        var fail = false
        let gate: AsyncStream<Void>?
        init(gate: AsyncStream<Void>? = nil) { self.gate = gate }
        func append(_ entry: DashboardNoteJournalEntry) async throws {
            values.append(entry.content)
            if values.count == 1, let gate {
                var iterator = gate.makeAsyncIterator()
                await iterator.next()
            }
            if fail { throw Failure.expected }
        }
        func setFailure(_ value: Bool) { fail = value }
    }
    private enum Failure: Error { case expected, timedOut }
    private func entry(_ content: String, revision: UInt64) -> DashboardNoteJournalEntry {
        .init(noteID: "note", title: "Draft", content: content, revision: revision)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func waitForFirstWrite(_ writes: Writes) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await writes.values.isEmpty {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            await Task.yield()
        }
    }

    @Test func delayedEditingResponsePreservesNewerUnsavedText() {
        var draft = DashboardNoteDraft(title: "Draft", content: "Already saved", saveState: .saved,
            editRevision: 1, persistedRevision: 1, sourceUpdatedAt: "initial")
        draft.edit(content: "Typed while the database was waiting")
        let response = NoteEditingResponse(success: true, noteID: "note", title: "Agent title", revision: "agent-revision")
        draft.adoptEditingResponse(response, content: "Earlier agent edit")
        #expect(draft.content == "Typed while the database was waiting")
        #expect(draft.title == "Draft")
        #expect(draft.saveState == .saving)
        #expect(draft.editRevision == 2)
        #expect(draft.persistedRevision == 1)
        draft.persistedRevision = 2
        draft.adoptEditingResponse(response, content: "A later confirmed edit")
        #expect(draft.content == "A later confirmed edit")
        #expect(draft.title == "Agent title")
        #expect(draft.saveState == .saved)
    }

    @Test func flushWaitsForSuspendedWriteAndSubsequentEditsRemainOrdered() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let writes = Writes(gate: gate.stream)
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("first", revision: 1))
        let first = Task { try await writer.flush() }
        try await waitForFirstWrite(writes)
        writer.submit(entry("second", revision: 2))
        writer.submit(entry("third", revision: 3))
        #expect(await writer.hasOutstandingWork())
        #expect(try journal.entries().map(\.content) == ["first"])
        let second = Task { try await writer.flush() }
        await MainActor.run { #expect(Thread.isMainThread) }
        gate.continuation.yield(())
        try await first.value
        try await second.value
        #expect(await writes.values == ["first", "third"])
        #expect(try journal.entries().isEmpty)
        #expect(await !writer.hasOutstandingWork())
    }

    @Test func failedAsyncWriteRetainsJournalAndReplayAcknowledgesIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = Writes()
        await writes.setFailure(true)
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("retained", revision: 1))
        await #expect(throws: Failure.expected) { try await writer.flush() }
        #expect(await writer.hasOutstandingWork())
        let retained = try journal.entries()
        #expect(retained.map(\.content) == ["retained"])
        await writes.setFailure(false)
        try await writer.replayAndFlush(retained)
        #expect(try journal.entries().isEmpty)
        #expect(await !writer.hasOutstandingWork())
        #expect(await writes.values == ["retained", "retained"])
    }

    @Test func appendFailureNeverCallsDatabaseAndCanRetryFromPendingDraft() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        final class AppendGate: @unchecked Sendable {
            let lock = NSLock()
            var fails = true
            func setFailure(_ value: Bool) { lock.withLock { fails = value } }
            func check() throws { if lock.withLock({ fails }) { throw Failure.expected } }
        }
        let append = AppendGate()
        let writes = Writes()
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"),
            beforeAppend: { try append.check() })
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("retry", revision: 1))
        await #expect(throws: Failure.expected) { try await writer.flush() }
        #expect(await writes.values.isEmpty)
        append.setFailure(false)
        try await writer.flush()
        #expect(await writes.values == ["retry"])
        #expect(try journal.entries().isEmpty)
    }
}
