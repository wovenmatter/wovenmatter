import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

struct NativeInteractionProjectionTests {
    @Test func nativePermissionIdentityAndOptionsPreserveProviderScopeWithoutInventingARun() async throws {
        let link = OpenCodeSessionLink(conversationID: "conversation", connectionID: "native", sessionID: "ses_a")
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.permissions = [["id": "per_a", "sessionID": "ses_a", "action": "bash",
            "resources": .array(["pwd"]), "save": .array(["shell:pwd"])],
            ["id": "per_foreign", "sessionID": "ses_b", "action": "bash", "resources": .array(["pwd"])]]
        let card = try #require(NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(card.runID == nil)
        #expect(card.options.map(\.id) == ["once", "always", "reject"])
        #expect(NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).count == 1)
        #expect(card.id == NativeInteractionProjection.id(link: link, kind: "permission", request: snapshot.permissions[0]))
        snapshot.permissions[0]["resources"] = .array(["rm file"])
        let changed = try #require(NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(changed.id != card.id)
        snapshot.permissions[0]["save"] = .array([])
        #expect(NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first?.options.map(\.id) == ["once", "reject"])
        snapshot.permissions[0]["action"] = "credential.read"
        let macOnly = try #require(NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: nil).first)
        #expect(macOnly.title == "Continue on your Mac")
        #expect(macOnly.options.isEmpty)
    }

}
