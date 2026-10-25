import Foundation
import Testing
@testable import WovenMatterClient

struct BackendInvalidationJournalTests {


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
