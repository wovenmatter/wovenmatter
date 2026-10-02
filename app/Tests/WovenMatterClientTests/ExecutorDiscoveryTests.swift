import Foundation
import Testing
@testable import WovenMatterClient

struct ExecutorDiscoveryTests {
    @Test func discoveredHTTPSNameDoesNotReplaceSSHIdentity() throws {
        let data = Data(#"{"Peer":{"one":{"HostName":"linux-box","DNSName":"linux-box.example.ts.net.","Online":true}}}"#.utf8)
        let machines = try RemoteMachineDiscovery.decodeTailnetMachines(from: data)
        #expect(machines.count == 1)
        #expect(machines[0].hostName == "linux-box")
        #expect(machines[0].dnsName == "linux-box.example.ts.net")
        #expect(machines[0].displayName == "linux-box")
    }
    @Test func olderDiscoverySnapshotsRemainReadable() throws {
        let data = Data(#"{"hostName":"linux-box","displayName":"Linux","online":true}"#.utf8)
        let machine = try JSONDecoder().decode(RemoteMachineCandidate.self, from: data)
        #expect(machine.hostName == "linux-box")
        #expect(machine.dnsName == nil)
    }
}
