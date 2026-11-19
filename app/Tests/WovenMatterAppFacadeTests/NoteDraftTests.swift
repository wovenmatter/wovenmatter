import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

private final class DraftFixtureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 1
    private var content = "base"
    private var receipts: [String: String] = [:]
    private var bases: [String?] = []
    func apply(_ entry: NoteJournalEntry) throws {
        try lock.withLock {
            if let id = entry.mutationID, receipts[id] != nil { return }
            bases.append(entry.expectedRevision)
            guard entry.expectedRevision == String(revision) else { throw DraftTestFailure.conflict }
            revision += 1; content = entry.content
            if let id = entry.mutationID { receipts[id] = String(revision) }
        }
    }
    func receipt(_ entry: NoteJournalEntry) -> String? { lock.withLock { entry.mutationID.flatMap { receipts[$0] } } }
    func externalWrite(_ value: String) { lock.withLock { revision += 1; content = value } }
    func snapshot() -> (Int, String, [String?]) { lock.withLock { (revision, content, bases) } }
}
private enum DraftTestFailure: Error, Equatable { case conflict }

struct NoteDraftTests {
    /// Unsaved writing the 0.4.6 release left in the journal holds documents
    /// as it wrote them. They are converted once, when the app starts, to
    /// documents this build saves; nothing else about an entry changes, and
    /// a journal without such an entry is not rewritten.
    @Test func unsavedWritingThePreviousReleaseLeftIsConvertedOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-draft-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "drafts.ndjson")
        let current = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Unsaved"))]).encoded()
        let base = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Saved"))]).encoded()
        func earlier(_ document: String) -> String { String(document.dropLast()) + #","version":2}"# }
        // The bytes 0.4.6 wrote: one entry a line.
        func line(_ mutation: String, content: String, base: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["writerSessionID": "writer", "mutationID": mutation, "noteID": "note", "title": "Title",
                "content": content, "revision": 3, "expectedRevision": "7", "baseContent": base, "baseTitle": "Title"], options: [.sortedKeys]) + Data([0x0A])
        }
        try (line("m1", content: earlier(current), base: earlier(base)) + line("m2", content: current, base: base)).write(to: file)
        #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: earlier(current)) }

        let journal = NoteDraftJournal(fileURL: file)
        try journal.convertEarlierDocuments()
        let entries = try journal.entries()
        #expect(entries.map(\.content) == [current, current] && entries.map(\.baseContent) == [base, base])
        #expect(entries.map(\.mutationID) == ["m1", "m2"] && entries.allSatisfy { $0.writerSessionID == "writer" && $0.expectedRevision == "7" && $0.revision == 3 })
        #expect(try NoteDocument.editableDocument(from: entries[0].content).plainText == "Unsaved")
        // Nothing is left to convert: the journal is not written again.
        let converted = try Data(contentsOf: file)
        let written = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try journal.convertEarlierDocuments()
        #expect(try Data(contentsOf: file) == converted)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == written)
        // No journal at all is nothing to convert, and none is created.
        let none = NoteDraftJournal(fileURL: directory.appending(path: "none.ndjson"))
        try none.convertEarlierDocuments()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "none.ndjson").path))
    }

    @Test func ownChainCASDelayedConflictRestartDurabilityRecoveryCopiesAndCanonicalRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-draft-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NoteDraftJournal(fileURL: directory.appending(path: "drafts.ndjson"))
        let store = DraftFixtureStore()
        let writer = NoteWriteBehind(journal: journal, coalescingDelay: .seconds(60), writerSessionID: "writer",
            update: { try store.apply($0) }, committedRevision: { store.receipt($0) }, completion: { _, _ in })
        func entry(_ content: String, revision: UInt64, expected: String = "1") -> NoteJournalEntry {
            NoteJournalEntry(noteID: "note", title: "Title", content: content, revision: revision,
                                      expectedRevision: expected, baseContent: "base", baseTitle: "Title")
        }
        let first = entry("first", revision: 1)
        writer.submit(first); try await writer.flush()
        #expect(store.receipt(first) == "2", "Exact accepted receipt must be retained")
        // The UI's main-actor completion can still be queued when another edit
        // arrives. Only this writer's acknowledged predecessor permits rebasing.
        writer.submit(entry("second", revision: 2)); try await writer.flush()
        #expect(store.snapshot().0 == 3 && store.snapshot().1 == "second", "Own queued edits must advance")
        #expect(store.snapshot().2 == ["1", "2"], "Own-chain CAS must use exact predecessor")
        store.externalWrite("phone")
        writer.submit(entry("third local writing", revision: 3))
        await #expect(throws: DraftTestFailure.conflict, "Expected conflict") { try await writer.flush() }
        #expect(store.snapshot().1 == "phone", "External writing must survive a delayed local completion")
        let retained = try writer.recoverableEntries()
        #expect(retained.count == 1 && retained[0].content == "third local writing", "Local conflict must remain durable")
        #expect(retained[0].expectedRevision == "3", "Journal must persist proven predecessor revision")
        #expect(store.receipt(first) == "2", "Later external commits cannot change prior receipt")
        let restarted = NoteWriteBehind(journal: journal, writerSessionID: "new-writer",
            update: { try store.apply($0) }, committedRevision: { store.receipt($0) }, completion: { _, _ in })
        await #expect(throws: DraftTestFailure.conflict, "Expected restart conflict") {
            try await restarted.replayAndFlush(journal.latestEntries())
        }
        #expect(store.snapshot().1 == "phone", "Restart must not silently overwrite")
        let otherWriter = NoteJournalEntry(writerSessionID: "other-writer", noteID: "note", title: "Other", content: "another recovered version", revision: 1)
        try journal.append(otherWriter)
        try restarted.discardRecoveredDraft(noteID: "note", content: "third local writing", title: "Title")
        let remaining = try restarted.recoverableEntries()
        #expect(remaining.count == 1 && remaining[0].content == otherWriter.content, "Recovery copy must preserve other writer versions")
        func note(_ content: String, revision: String) throws -> WorkspaceNoteRecord {
            let data = try JSONSerialization.data(withJSONObject: ["id": "note", "title": "Title",
                "content": content, "revision": revision, "created_at": "2026-09-21T12:00:00Z",
                "updated_at": "2026-09-21T12:00:00Z"])
            return try JSONDecoder().decode(WorkspaceNoteRecord.self, from: data)
        }
        var draft = NoteDraft.initial(for: try note("base", revision: "1"))
        draft.edit(content: "local accepted")
        draft.persistedRevision = draft.editRevision
        draft.reconcile(with: try note("external accepted", revision: "2"))
        #expect(draft.content == "external accepted" && draft.sourceRevision == "2",
                "Canonical revision must win even when updates share the same timestamp")
    }
}
