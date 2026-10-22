import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionMacDiscoveryTests {
    private var status: Data { Data(#"{"BackendState":"Running","Self":{"DNSName":"self.tail.ts.net."},"Peer":{"mac":{"Online":true,"OS":"macOS","DNSName":"mac.tail.ts.net."},"offline":{"Online":false,"OS":"macOS","DNSName":"offline.tail.ts.net."},"linux":{"Online":true,"OS":"linux","DNSName":"linux.tail.ts.net."},"phone":{"Online":true,"OS":"iOS","DNSName":"phone.tail.ts.net."},"outside":{"Online":true,"OS":"macOS","DNSName":"not-private.example"},"injection":{"Online":true,"OS":"macOS","DNSName":"host/other.tail.ts.net"}}}"#.utf8) }
    @Test func candidatesAreOnlyOnlineTailnetMacsAndKnownApplicationPorts() throws {
        let urls = try CompanionMacDiscovery.candidates(status: status)
        #expect(urls.count == 4)
        #expect(Set(urls.compactMap(\.port)) == Set(CompanionMacDiscovery.ports))
        #expect(urls.allSatisfy { $0.host == "mac.tail.ts.net" && $0.scheme == "https" && $0.path == "/wovenmatter" })
    }
    @Test func discoveryRejectsInvalidAdvertisementsWithoutBroadProbing() async throws {
        let recorder = DiscoveryRecorder(), input = status
        let discovery = CompanionMacDiscovery(status: { input }, probe: { endpoint in
            await recorder.record(endpoint)
            switch endpoint.port {
            case 8443: return .init(role: .central, identity: .init(deviceID: "bad-id", deviceName: "Bad", metadata: .init(kind: .mac)))
            case 10_000: return .init(role: .client, identity: .init(deviceID: UUID().uuidString, deviceName: "Bad\nName", metadata: .init(kind: .mac)))
            case 8444: return .init(role: .client, identity: .init(deviceID: UUID().uuidString, deviceName: "Phone", metadata: .init(kind: .iPhone)))
            default: return .init(role: .central, identity: .init(deviceID: UUID().uuidString, deviceName: "Mac", metadata: .init(kind: .mac)))
            }
        })
        let peers = try await discovery.discover()
        #expect(peers.count == 1 && peers.first?.endpoint.port == 8445)
        #expect(await recorder.urls.count == 4)
    }
}
private actor DiscoveryRecorder {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
