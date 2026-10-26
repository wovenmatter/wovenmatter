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

}
