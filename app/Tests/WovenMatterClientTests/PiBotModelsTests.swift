import Foundation
import Testing
@testable import WovenMatterClient

struct PiBotModelsTests {
    private func bot(_ id: String, kind: String = "bot", manager: Bool = false, managerId: String? = nil,
                     orchestrator: Bool = false, group: String? = nil) -> PiBotSummary {
        PiBotSummary(id: id, name: id, kind: kind, manager: manager, managerId: managerId, orchestrator: orchestrator, groupId: group)
    }

    @Test func threadsListPinnedFirstThenNewestCreated() {
        let threads = [
            PiBotThread(conversationId: 1, title: "old", createdAt: "2026-01-01T00:00:00Z"),
            PiBotThread(conversationId: 2, title: "pinned old", createdAt: "2026-01-02T00:00:00Z", pinned: true),
            PiBotThread(conversationId: 3, title: "new", createdAt: "2026-03-01T00:00:00Z"),
            PiBotThread(conversationId: 4, title: "pinned new", createdAt: "2026-02-01T00:00:00Z", pinned: true),
            PiBotThread(conversationId: 5, title: nil, createdAt: "2026-03-01T00:00:00Z"),
        ]
        #expect(PiBotThread.sorted(threads).map(\.conversationId) == [4, 2, 5, 3, 1])
        #expect(threads[4].label == "Untitled thread")
    }

    @Test func sidebarPinsAdminAndOrchestratorThenGroupsThenTheRest() {
        let layout = PiBotSidebarLayout(bots: [
            bot("plain"), bot("grouped", group: "g2"), bot("admin", kind: "admin"), bot("lead", orchestrator: true),
            bot("first", group: "g1"),
        ], groups: [PiBotGroup(id: "g2", name: "Two", position: 2), PiBotGroup(id: "g1", name: "One", position: 1)])
        #expect(layout.pinned.map(\.id) == ["admin", "lead"])
        #expect(layout.groups.map(\.id) == ["g1", "g2"])
        #expect(layout.groups[0].rows.map(\.id) == ["first"])
        #expect(layout.groups[1].rows.map(\.id) == ["grouped"])
        #expect(layout.ungrouped.map(\.id) == ["plain"])
    }

    @Test func teamMembersNestUnderTheirManagerInTheSameList() {
        let layout = PiBotSidebarLayout(bots: [
            bot("member", managerId: "manager"), bot("solo"), bot("manager", manager: true),
        ], groups: [])
        #expect(layout.ungrouped.map(\.id) == ["manager", "member", "solo"])
        #expect(layout.ungrouped.map(\.isTeamMember) == [false, true, false])
    }

    @Test func aGroupedTeamMemberLeavesItsTeamForPlacementOnly() {
        let layout = PiBotSidebarLayout(bots: [
            bot("manager", manager: true), bot("member", managerId: "manager", group: "g"), bot("other", managerId: "manager"),
        ], groups: [PiBotGroup(id: "g", name: "G", position: 0)])
        #expect(layout.groups[0].rows.map(\.id) == ["member"])
        #expect(layout.groups[0].rows[0].isTeamMember == false)
        #expect(layout.ungrouped.map(\.id) == ["manager", "other"])
    }

    @Test func orchestratorKeepsItsOwnTeamBesideIt() {
        let layout = PiBotSidebarLayout(bots: [
            bot("admin", kind: "admin"), bot("lead", manager: true, orchestrator: true), bot("member", managerId: "lead"), bot("solo"),
        ], groups: [])
        #expect(layout.pinned.map(\.id) == ["admin", "lead", "member"])
        #expect(layout.pinned.map(\.isTeamMember) == [false, false, true])
        #expect(layout.ungrouped.map(\.id) == ["solo"])
    }

    @Test func aBotInAnUnknownGroupStaysVisible() {
        let layout = PiBotSidebarLayout(bots: [bot("lost", group: "gone")], groups: [])
        #expect(layout.ungrouped.map(\.id) == ["lost"])
    }

    @Test func everyBotAppearsExactlyOnce() {
        let bots = [bot("admin", kind: "admin"), bot("lead", manager: true, orchestrator: true), bot("a", managerId: "lead"),
                    bot("m", manager: true), bot("b", managerId: "m"), bot("c", group: "g"), bot("d")]
        let ids = PiBotSidebarLayout(bots: bots, groups: [PiBotGroup(id: "g", name: "G", position: 0)]).allRows.map(\.id)
        #expect(ids.sorted() == bots.map(\.id).sorted())
    }

    @Test func toleratesFieldsAddedUpstream() throws {
        let data = Data(#"{"id":"x","name":"X","createdAt":"t","kind":"bot","manager":false,"orchestrator":false,"profileId":"p","profileName":"P","defaultProfile":true,"somethingNew":1}"#.utf8)
        let bot = try JSONDecoder().decode(PiBotSummary.self, from: data)
        #expect(bot.groupId == nil && !bot.isAdmin)
    }
}
