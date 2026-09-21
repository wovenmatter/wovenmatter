import Foundation
import WovenMatterCore

private final class DraftFixtureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 1
    private var content = "base"
    private var receipts: [String: String] = [:]
    private var bases: [String?] = []
    func apply(_ entry: DashboardNoteJournalEntry) throws {
        try lock.withLock {
            if let id = entry.mutationID, receipts[id] != nil { return }
            bases.append(entry.expectedRevision)
            guard entry.expectedRevision == String(revision) else { throw DraftTestFailure.conflict }
            revision += 1; content = entry.content
            if let id = entry.mutationID { receipts[id] = String(revision) }
        }
    }
    func receipt(_ entry: DashboardNoteJournalEntry) -> String? { lock.withLock { entry.mutationID.flatMap { receipts[$0] } } }
    func externalWrite(_ value: String) { lock.withLock { revision += 1; content = value } }
    func snapshot() -> (Int, String, [String?]) { lock.withLock { (revision, content, bases) } }
}
private enum DraftTestFailure: Error { case conflict, assertion(String) }

@main
struct DashboardNoteDraftTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DraftTestFailure.assertion(message) }
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-draft-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DashboardNoteDraftJournal(fileURL: directory.appending(path: "drafts.ndjson"))
        let store = DraftFixtureStore()
        let writer = DashboardNoteWriteBehind(journal: journal, coalescingDelay: .seconds(60), writerSessionID: "writer",
            update: { try store.apply($0) }, committedRevision: { store.receipt($0) }, completion: { _, _ in })
        func entry(_ content: String, revision: UInt64, expected: String = "1") -> DashboardNoteJournalEntry {
            DashboardNoteJournalEntry(noteID: "note", title: "Title", content: content, revision: revision,
                                      expectedRevision: expected, baseContent: "base", baseTitle: "Title")
        }
        let first = entry("first", revision: 1)
        writer.submit(first); try writer.flush()
        try require(store.receipt(first) == "2", "Exact accepted receipt must be retained")
        // The UI's main-actor completion can still be queued when another edit
        // arrives. Only this writer's acknowledged predecessor permits rebasing.
        writer.submit(entry("second", revision: 2)); try writer.flush()
        try require(store.snapshot().0 == 3 && store.snapshot().1 == "second", "Own queued edits must advance")
        try require(store.snapshot().2 == ["1", "2"], "Own-chain CAS must use exact predecessor")
        store.externalWrite("phone")
        writer.submit(entry("third local writing", revision: 3))
        do { try writer.flush(); throw DraftTestFailure.assertion("Expected conflict") }
        catch DraftTestFailure.conflict {}
        try require(store.snapshot().1 == "phone", "External writing must survive a delayed local completion")
        let retained = try writer.recoverableEntries()
        try require(retained.count == 1 && retained[0].content == "third local writing", "Local conflict must remain durable")
        try require(retained[0].expectedRevision == "3", "Journal must persist proven predecessor revision")
        try require(store.receipt(first) == "2", "Later external commits cannot change prior receipt")
        let restarted = DashboardNoteWriteBehind(journal: journal, writerSessionID: "new-writer",
            update: { try store.apply($0) }, committedRevision: { store.receipt($0) }, completion: { _, _ in })
        do { try await restarted.replayAndFlush(journal.latestEntries()); throw DraftTestFailure.assertion("Expected restart conflict") }
        catch DraftTestFailure.conflict {}
        try require(store.snapshot().1 == "phone", "Restart must not silently overwrite")
        let otherWriter = DashboardNoteJournalEntry(writerSessionID: "other-writer", noteID: "note", title: "Other", content: "another recovered version", revision: 1)
        try journal.append(otherWriter)
        try restarted.discardRecoveredDraft(noteID: "note", content: "third local writing", title: "Title")
        let remaining = try restarted.recoverableEntries()
        try require(remaining.count == 1 && remaining[0].content == otherWriter.content, "Recovery copy must preserve other writer versions")
        func note(_ content: String, revision: String) throws -> WorkspaceNoteRecord {
            let data = try JSONSerialization.data(withJSONObject: ["id": "note", "title": "Title",
                "content": content, "revision": revision, "created_at": "2026-09-21T12:00:00Z",
                "updated_at": "2026-09-21T12:00:00Z"])
            return try JSONDecoder().decode(WorkspaceNoteRecord.self, from: data)
        }
        var draft = DashboardNoteDraft.initial(for: try note("base", revision: "1"))
        draft.edit(content: "local accepted")
        draft.persistedRevision = draft.editRevision
        draft.reconcile(with: try note("external accepted", revision: "2"))
        try require(draft.content == "external accepted" && draft.sourceRevision == "2",
                    "Canonical revision must win even when updates share the same timestamp")
        print("PASS: draft own-chain CAS, delayed-completion conflict, restart durability, recovery copies, and canonical revision reconciliation")
    }
}
