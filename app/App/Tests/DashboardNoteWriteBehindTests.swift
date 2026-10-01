@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterCore

@Suite("Async note write-behind")
struct DashboardNoteWriteBehindTests {
    private actor Writes {
        var values: [String] = []
        var fail = false
        let gate: AsyncStream<Void>?
        let started: AsyncStream<Void>.Continuation?
        init(gate: AsyncStream<Void>? = nil, started: AsyncStream<Void>.Continuation? = nil) {
            self.gate = gate
            self.started = started
        }
        func append(_ entry: DashboardNoteJournalEntry) async throws {
            values.append(entry.content)
            started?.yield(())
            if values.count == 1, let gate {
                var iterator = gate.makeAsyncIterator()
                await iterator.next()
            }
            if fail { throw Failure.expected }
        }
        func setFailure(_ value: Bool) { fail = value }
    }
    private enum Failure: Error { case expected }
    private func entry(_ content: String, revision: UInt64) -> DashboardNoteJournalEntry {
        .init(noteID: "note", title: "Draft", content: content, revision: revision)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func snapshotReconciliationPreservesUnsavedTextAndAdoptsCurrentSavedText() throws {
        func note(_ content: String, revision: String) throws -> WorkspaceNoteRecord {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "note", "title": "Draft", "content": content, "updated_at": revision,
            ])
            return try JSONDecoder().decode(WorkspaceNoteRecord.self, from: data)
        }
        var draft = DashboardNoteDraft.initial(for: try note("Initial", revision: "initial"))
        draft.edit(content: "Typed while the database was waiting")
        draft.reconcile(with: try note("Earlier agent edit", revision: "agent"))
        #expect(draft.content == "Typed while the database was waiting")
        #expect(draft.saveState == .saving)
        draft.persistedRevision = draft.editRevision
        draft.reconcile(with: try note("Typed while the database was waiting", revision: "saved"))
        #expect(draft.content == "Typed while the database was waiting")
        #expect(draft.sourceUpdatedAt == "saved")
        #expect(draft.saveState == .saved)
        draft.reconcile(with: try note("Latest committed agent edit", revision: "latest"))
        #expect(draft.content == "Latest committed agent edit")
        #expect(draft.sourceUpdatedAt == "latest")
    }

    @Test func flushWaitsForSuspendedWriteAndSubsequentEditsRemainOrdered() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = AsyncStream<Void>.makeStream()
        let writes = Writes(gate: gate.stream, started: started.continuation)
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("first", revision: 1))
        let first = Task { try await writer.flush() }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
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

    @Test func emptyFlushBarrierReportsEarlierAsynchronousFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = AsyncStream<Void>.makeStream()
        let writes = Writes(gate: gate.stream, started: started.continuation)
        await writes.setFailure(true)
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("not committed", revision: 1))
        let first = Task { try await writer.flush() }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        let barrier = Task { try await writer.flush() }
        gate.continuation.yield(())
        await #expect(throws: Failure.expected) { try await first.value }
        await #expect(throws: Failure.expected) { try await barrier.value }
        #expect(try journal.entries().map(\.content) == ["not committed"])
        await #expect(throws: Failure.expected) { try await writer.flush() }
    }

    @Test func newerCommittedDraftClearsFailureForSupersededJournalEntry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = Writes()
        await writes.setFailure(true)
        let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60),
            update: { try await writes.append($0) }, completion: { _, _ in })
        writer.submit(entry("failed old edit", revision: 1))
        await #expect(throws: Failure.expected) { try await writer.flush() }
        await writes.setFailure(false)
        writer.submit(entry("new edit", revision: 2))
        try await writer.flush()
        try await writer.flush()
        #expect(try journal.entries().isEmpty)
        #expect(await writes.values == ["failed old edit", "new edit"])
    }

}
