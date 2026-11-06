import Foundation
import Testing
@testable import WovenMatterClient

struct PiBotModelsTests {
    private static func fixtureIP(_ last: Int) -> String { [100, 64, 0, last].map(String.init).joined(separator: ".") }
    private static let publicIP = [192, 0, 2, 1].map(String.init).joined(separator: ".")

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
      "mini":{"Online":true,"OS":"macOS","HostName":"Mac Mini","DNSName":"mini.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(2))"]},
      "box":{"Online":true,"OS":"linux","HostName":"box","DNSName":"box.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(3))"]},
      "off":{"Online":false,"OS":"linux","HostName":"off","DNSName":"off.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(4))"]},
      "phone":{"Online":true,"OS":"iOS","HostName":"phone","DNSName":"phone.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(5))"]},
      "expired":{"Online":true,"Expired":true,"OS":"linux","HostName":"expired","DNSName":"e.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(6))"]},
      "public":{"Online":true,"OS":"linux","HostName":"public","DNSName":"p.tail.ts.net.","TailscaleIPs":["\#(Self.publicIP)"]},
      "self":{"Online":true,"OS":"macOS","HostName":"air","DNSName":"air.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(7))"]}
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
        PiBotTailnetPeer(id: "box", name: "box", dnsName: "box.tail.ts.net", address: Self.fixtureIP(3), system: .linux, online: true)
    }

    @Test func sshIsPinnedToTailscaleAndNonInteractive() throws {
        let args = try PiBotTailnet.sshArguments(peer: peer, user: "trey", tailscale: "/ts")
        #expect(args.last == "trey@box")
        for option in ["Hostname=\(Self.fixtureIP(3))", "HostKeyAlias=\(Self.fixtureIP(3))", "StrictHostKeyChecking=yes", "BatchMode=yes", "ProxyJump=none", "ForwardAgent=no", "PasswordAuthentication=no"] {
            #expect(args.contains(option))
        }
        #expect(args.contains { $0.contains(" nc \(Self.fixtureIP(3)) %p") })
        #expect(throws: (any Error).self) { try PiBotTailnet.sshArguments(peer: peer, user: "-oProxyCommand=bad", tailscale: "/ts") }
        #expect(throws: (any Error).self) { try PiBotTailnet.sshArguments(peer: peer, user: "a b", tailscale: "/ts") }
    }

    @Test func tunnelRunsOneCommandAndKeepsItLastWithoutPortForwards() throws {
        let ssh = try PiBotTailnet.sshArguments(peer: peer, user: "", tailscale: "/ts")
        let command = PiBotTunnel.remoteCommand(instance: "dev", relaySource: "source", forward: .init(localPort: 40001, remotePort: 47310, mcpRemotePort: 47500, mcpLocalPort: 51000))
        let args = PiBotTunnel.arguments(ssh: ssh, remoteCommand: command)
        #expect(args.last == command)
        #expect(args[args.count - 2] == "box")
        #expect(!args.contains("-L") && !args.contains("-R") && !args.contains("-N"))
        #expect(command.hasSuffix("'dev' 'source' '47310' '47500'"))
        let noMCP = PiBotTunnel.remoteCommand(instance: "dev", relaySource: "source", forward: .init(localPort: 40001, remotePort: 47310))
        #expect(noMCP.hasSuffix("'47310' 'none'"))
        let firstUse = PiBotTunnel.remoteCommand(instance: "dev", relaySource: "source", forward: .init(localPort: 40001, remotePort: 47310, mcpLocalPort: 51000))
        #expect(firstUse.hasSuffix("'47310' '0'"))
    }

    @Test func aDeviceWithALiveTunnelIsReachableEvenWhenTheCoordinationServerLostIt() throws {
        let formatter = ISO8601DateFormatter()
        func decode(online: Bool, active: Bool, handshake: Date) throws -> Bool {
            let json: [String: Any] = ["BackendState": "Running", "Self": ["DNSName": "me.tail.ts.net."], "Peer": ["key": [
                "HostName": "box", "DNSName": "box.tail.ts.net.", "OS": "linux", "TailscaleIPs": [Self.fixtureIP(3)],
                "Online": online, "Active": active, "LastHandshake": formatter.string(from: handshake)]]]
            return try #require(try PiBotTailnet.decode(JSONSerialization.data(withJSONObject: json)).first).online
        }
        #expect(try decode(online: true, active: false, handshake: .distantPast))
        #expect(try decode(online: false, active: true, handshake: Date()))
        #expect(try !decode(online: false, active: true, handshake: Date().addingTimeInterval(-3600)))
        #expect(try !decode(online: false, active: false, handshake: Date()))
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
