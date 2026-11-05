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

    static let status = Data(#"""
    {"BackendState":"Running","Self":{"DNSName":"air.tail.ts.net."},"Peer":{
      "mini":{"Online":true,"OS":"macOS","HostName":"Mac Mini","DNSName":"mini.tail.ts.net.","TailscaleIPs":["100.64.0.2"]},
      "box":{"Online":true,"OS":"linux","HostName":"box","DNSName":"box.tail.ts.net.","TailscaleIPs":["100.64.0.3"]},
      "off":{"Online":false,"OS":"linux","HostName":"off","DNSName":"off.tail.ts.net.","TailscaleIPs":["100.64.0.4"]},
      "phone":{"Online":true,"OS":"iOS","HostName":"phone","DNSName":"phone.tail.ts.net.","TailscaleIPs":["100.64.0.5"]},
      "expired":{"Online":true,"Expired":true,"OS":"linux","HostName":"expired","DNSName":"e.tail.ts.net.","TailscaleIPs":["100.64.0.6"]},
      "public":{"Online":true,"OS":"linux","HostName":"public","DNSName":"p.tail.ts.net.","TailscaleIPs":["192.0.2.1"]},
      "self":{"Online":true,"OS":"macOS","HostName":"air","DNSName":"air.tail.ts.net.","TailscaleIPs":["100.64.0.7"]}
    }}
    """#.utf8)

    @Test func tailnetOffersMacsAndLinuxButNotPhonesExpiredPublicOrSelf() throws {
        let peers = try PiBotTailnet.decode(Self.status)
        #expect(Set(peers.map(\.id)) == ["mini", "box", "off"])
        #expect(peers.first { $0.id == "mini" }?.system == .macOS)
        #expect(peers.first { $0.id == "box" }?.system == .linux)
        #expect(peers.first { $0.id == "off" }?.online == false)
        #expect(throws: (any Error).self) { try PiBotTailnet.decode(Data(#"{"BackendState":"Stopped"}"#.utf8)) }
    }

    private var peer: PiBotTailnetPeer {
        PiBotTailnetPeer(id: "box", name: "box", dnsName: "box.tail.ts.net", address: "100.64.0.3", system: .linux, online: true)
    }

    @Test func sshIsPinnedToTailscaleAndNonInteractive() throws {
        let args = try PiBotTailnet.sshArguments(peer: peer, user: "trey", tailscale: "/ts")
        #expect(args.last == "trey@box")
        for option in ["Hostname=100.64.0.3", "HostKeyAlias=100.64.0.3", "StrictHostKeyChecking=yes", "BatchMode=yes", "ProxyJump=none", "ForwardAgent=no", "PasswordAuthentication=no"] {
            #expect(args.contains(option))
        }
        #expect(args.contains { $0.contains(" nc 100.64.0.3 %p") })
        #expect(throws: (any Error).self) { try PiBotTailnet.sshArguments(peer: peer, user: "-oProxyCommand=bad", tailscale: "/ts") }
        #expect(throws: (any Error).self) { try PiBotTailnet.sshArguments(peer: peer, user: "a b", tailscale: "/ts") }
    }

    @Test func tunnelForwardsLoopbackOnlyAndKeepsTheDestinationLast() throws {
        let ssh = try PiBotTailnet.sshArguments(peer: peer, user: "", tailscale: "/ts")
        let args = PiBotTunnel.arguments(ssh: ssh, forward: .init(localPort: 40001, remotePort: 47310, mcpRemotePort: 47500, mcpLocalPort: 51000))
        #expect(args.last == "box")
        #expect(args.contains("127.0.0.1:40001:127.0.0.1:47310"))
        #expect(args.contains("127.0.0.1:47500:127.0.0.1:51000"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
        let noMCP = PiBotTunnel.arguments(ssh: ssh, forward: .init(localPort: 40001, remotePort: 47310))
        #expect(!noMCP.contains("-R"))
    }

    @Test func scriptFailuresPreferTheirDetailOverRawOutput() {
        #expect(PiBotHostRunner.failureMessage("WM_PROGRESS node\n{\"error\":\"checksum\",\"detail\":\"The Node archive did not match.\"}") == "The Node archive did not match.")
        #expect(PiBotHostRunner.failureMessage("Host key verification failed.").contains("host key"))
        #expect(PiBotHostRunner.failureMessage("trey@box: Permission denied (publickey).").contains("refused"))
    }

    @Test func updatesAreOfferedOnlyForManagedDeploymentsOnAnOlderCommit() {
        var snapshot = PiBotRuntimeSnapshot(target: .thisMac, installedCommit: "a", bundledCommit: "b")
        #expect(snapshot.updateAvailable)
        snapshot.installedCommit = "b"
        #expect(!snapshot.updateAvailable)
        snapshot.installedCommit = "a"
        snapshot.target = PiBotDeploymentTarget(kind: .tailnet, ownership: .attached, peer: peer)
        #expect(!snapshot.updateAvailable)
    }

    @Test func toleratesFieldsAddedUpstream() throws {
        let data = Data(#"{"id":"x","name":"X","createdAt":"t","kind":"bot","manager":false,"orchestrator":false,"profileId":"p","profileName":"P","defaultProfile":true,"somethingNew":1}"#.utf8)
        let bot = try JSONDecoder().decode(PiBotSummary.self, from: data)
        #expect(bot.groupId == nil && !bot.isAdmin)
    }
}
