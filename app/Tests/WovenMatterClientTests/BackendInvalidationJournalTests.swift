import Foundation
import Testing
@testable import WovenMatterClient

struct BackendInvalidationJournalTests {
    private actor Received {
        var scopes: [Set<BackendInvalidationScope>] = []
        var conversations: [Set<String>] = []
        func add(_ scopes: Set<BackendInvalidationScope>, _ ids: Set<String>) { self.scopes.append(scopes); conversations.append(ids) }
    }

    @Test func everyPublicationReachesTheListenerInOrder() async {
        let journal = BackendInvalidationJournal(), received = Received()
        await journal.setListener { scopes, ids in await received.add(scopes, ids) }
        await journal.publish(scopes: [.permissions], conversationIDs: ["active"])
        await journal.publish()
        await journal.publish(conversationIDs: ["other"])
        #expect(await received.scopes == [[.permissions], []])
        #expect(await received.conversations == [["active"], ["other"]])
    }
}
