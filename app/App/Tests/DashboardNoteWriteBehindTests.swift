@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterCore

@Suite("Async note write-behind")
struct DashboardNoteWriteBehindTests {
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
