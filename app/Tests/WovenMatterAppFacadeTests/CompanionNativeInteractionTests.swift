import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

struct CompanionNativeInteractionTests {
    @Test func nativePermissionIdentityAndOptionsPreserveProviderScopeWithoutInventingARun() throws {
        let link = OpenCodeSessionLink(conversationID: "conversation", connectionID: "native", sessionID: "ses_a")
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.permissions = [["id": "per_a", "sessionID": "ses_a", "action": "bash",
            "resources": .array(["pwd"]), "save": .array(["shell:pwd"])],
            ["id": "per_foreign", "sessionID": "ses_b", "action": "bash", "resources": .array(["pwd"])]]
        let card = try #require(CompanionNativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(card.runID == nil)
        #expect(card.options.map(\.id) == ["once", "always", "reject"])
        #expect(CompanionNativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).count == 1)
        #expect(card.id == CompanionNativeInteractionProjection.id(link: link, kind: "permission", request: snapshot.permissions[0]))
        snapshot.permissions[0]["resources"] = .array(["rm file"])
        let changed = try #require(CompanionNativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(changed.id != card.id)
        snapshot.permissions[0]["save"] = .array([])
        #expect(CompanionNativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first?.options.map(\.id) == ["once", "reject"])
    }

    @Test func formsRemainOnMacAndFieldValuesCannotEnterPhoneCommandJournal() throws {
        let link = OpenCodeSessionLink(conversationID: "conversation", connectionID: "native", sessionID: "ses_a")
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.forms = [["id": "form_a", "fields": .array([["key": "secret", "default": "private fixture"]])]]
        let card = try #require(CompanionNativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(card.title == "Continue on your Mac")
        #expect(card.questions.isEmpty && card.options.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        #expect(!encoded.contains("private fixture"))
        let reply = CompanionCommand(deviceID: "device", kind: .respond, conversationID: "conversation",
            interactionID: card.id, response: .init(answers: ["secret": ["private fixture"]]))
        #expect(!CompanionNativeInteractionProjection.responseIsSafeToJournal(reply))
        let cancel = CompanionCommand(deviceID: "device", kind: .respond, conversationID: "conversation",
            interactionID: card.id, response: .init(cancelled: true))
        #expect(CompanionNativeInteractionProjection.responseIsSafeToJournal(cancel))
    }
}
