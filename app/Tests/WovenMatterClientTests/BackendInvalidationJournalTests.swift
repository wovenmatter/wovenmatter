import Foundation
import Testing
@testable import WovenMatterClient

struct BackendInvalidationJournalTests {

    @Test func coalescesOnlyChangesSinceCursor() async {
        let journal = BackendInvalidationJournal()
        let initial = await journal.changes(after: nil)
        #expect(initial.requiresReload)
        await journal.publish(scopes: [.calendar], conversationIDs: ["one"])
        await journal.publish(scopes: [.permissions], conversationIDs: ["one", "two"])
        let delta = await journal.changes(after: initial.cursor)
        #expect(!delta.requiresReload)
        #expect(delta.scopes == [.calendar, .permissions])
        #expect(delta.conversationIDs == ["one", "two"])
        let unchanged = await journal.changes(after: delta.cursor)
        #expect(!unchanged.requiresReload)
        #expect(unchanged.conversationIDs.isEmpty)
        #expect(unchanged.scopes.isEmpty)
    }


    @Test func evictedOrRestartedCursorRequiresReload() async {
        let journal = BackendInvalidationJournal(capacity: 1)
        let initial = await journal.changes(after: nil)
        await journal.publish(scopes: [.workspace])
        await journal.publish(scopes: [.calendar])
        #expect(await journal.changes(after: initial.cursor).requiresReload)
        let otherService = BackendInvalidationCursor(instanceID: UUID(), revision: 2)
        #expect(await journal.changes(after: otherService).requiresReload)
    }
    @Test func waitingClientWakesOnChange() async {
        let journal = BackendInvalidationJournal()
        let initial = await journal.changes(after: nil)
        let waiting = Task { await journal.waitForChanges(after: initial.cursor) }
        await journal.publish(scopes: [.permissions], conversationIDs: ["active"])
        let delta = await waiting.value
        #expect(delta.conversationIDs == ["active"])
        #expect(delta.scopes == [.permissions])
    }

}
