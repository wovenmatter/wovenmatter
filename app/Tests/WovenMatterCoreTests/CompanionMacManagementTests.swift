import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionMacManagementTests {
    private static func fixtureIP(_ last: Int) -> String { [100, 64, 0, last].map(String.init).joined(separator: ".") }
    static let status = Data(#"{"BackendState":"Running","Self":{"DNSName":"air.tail.ts.net."},"Peer":{"mini":{"Online":true,"OS":"macOS","HostName":"Mac mini","DNSName":"mini.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(2))"]},"offline":{"Online":false,"OS":"darwin","DNSName":"offline.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(2))"]},"linux":{"Online":true,"OS":"linux","DNSName":"linux.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(3))"]},"self":{"Online":true,"OS":"macOS","DNSName":"air.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(4))"]},"expired":{"Online":true,"Expired":true,"OS":"macOS","DNSName":"expired.tail.ts.net.","TailscaleIPs":["\#(Self.fixtureIP(5))"]},"public":{"Online":true,"OS":"macOS","DNSName":"bad.tail.ts.net.","TailscaleIPs":["\#([192, 0, 2, 1].map(String.init).joined(separator: "."))"]}}}"#.utf8)
    static let installed = Data("woven-mac-inspection-v1\ninstalled\n0.3.2\n900\n\n0\narm64\n27.2\n\n\n".utf8)
    static let missing = Data("woven-mac-inspection-v1\nmissing\n\n\n\n0\narm64\n27.2\n\n\n".utf8)
    private var mini: CompanionTailnetMac { get throws { try #require(CompanionTailnetMac.decode(Self.status).first { $0.id == "mini" }) } }

    @Test func inventoryIncludesStoppedUninstalledAndOfflineMacsWithoutAServiceProbe() throws {
        let macs = try CompanionTailnetMac.decode(Self.status)
        #expect(Set(macs.map(\.id)) == ["mini", "offline"])
        #expect(macs.first { $0.id == "offline" }?.online == false)
        #expect(try mini.sshName == "mini")
    }
    @Test func disconnectedTailnetIsAnErrorAndEmptyRunningTailnetIsAValidEmptyResult() throws {
        #expect(throws: (any Error).self) { try CompanionTailnetMac.decode(Data(#"{"BackendState":"Stopped"}"#.utf8)) }
        #expect(try CompanionTailnetMac.decode(Data(#"{"BackendState":"Running"}"#.utf8)).isEmpty)
    }
    @Test func inventoryDoesNotDependOnMagicDNSOrIPv4() throws {
        let input = Data(#"{"BackendState":"Running","Peer":{"ipv6":{"Online":true,"OS":"macOS","HostName":"Studio Mac","TailscaleIPs":["fd7a:115c:a1e0::2"]}}}"#.utf8)
        let mac = try #require(CompanionTailnetMac.decode(input).first)
        #expect(mac.dnsName.isEmpty && mac.name == "Studio Mac")
        let args = try CompanionMacManagement.sshArguments(mac: mac, connection: .init(alias: ""), tailscale: "/tailscale")
        #expect(args.contains("Hostname=fd7a:115c:a1e0::2"))
    }
    @Test func stoppedAppHasAVersionAndIsDistinctFromMissingOrUninspectable() throws {
        let stopped = try CompanionMacInstallation(data: Self.installed)
        #expect(stopped.installed && !stopped.running && !stopped.supportsSetup)
        #expect(stopped.version == "0.3.2" && stopped.build == 900)
        #expect(try !CompanionMacInstallation(data: Self.missing).installed)
        #expect(throws: (any Error).self) { try CompanionMacInstallation(data: Data("permission denied".utf8)) }
    }
    @Test func sshIsPinnedToTailnetAndKeepsExistingAliasCredentialsWithoutPrompts() throws {
        let args = try CompanionMacManagement.sshArguments(mac: mini, connection: .init(alias: "mini-config", user: "trey"), tailscale: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(args.last == "trey@mini-config")
        for option in ["Hostname=\(Self.fixtureIP(2))", "HostKeyAlias=\(Self.fixtureIP(2))", "StrictHostKeyChecking=yes", "ProxyJump=none", "ControlPath=none", "ForwardAgent=no", "BatchMode=yes", "PasswordAuthentication=no"] {
            #expect(args.contains(option))
        }
        #expect(args.contains { $0.contains(" nc \(Self.fixtureIP(2)) %p") })
        #expect(throws: (any Error).self) { try CompanionMacManagement.sshArguments(mac: mini, connection: .init(alias: "mini; touch /tmp/oops"), tailscale: "/tailscale") }
        #expect(throws: (any Error).self) { try CompanionMacManagement.sshArguments(mac: mini, connection: .init(alias: "mini", user: "-oProxyCommand=bad"), tailscale: "/tailscale") }
    }
    @Test func inspectionUsesSshEvenWhenNoPairingServiceRuns() async throws {
        let calls = MacManagementCalls()
        let manager = CompanionMacManagement(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, args, _ in
            await calls.append(executable.lastPathComponent.lowercased())
            return executable.lastPathComponent == "ssh" ? Self.installed : Self.status
        })
        let state = try await manager.inspect(mini, connection: .init(alias: "mini"))
        #expect(state.version == "0.3.2")
        #expect(await calls.items == ["tailscale", "ssh"])
    }
    @Test func vanishedPeerPreventsRemoteMutation() async throws {
        let calls = MacManagementCalls()
        let manager = CompanionMacManagement(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, _, _ in
            await calls.append(executable.lastPathComponent.lowercased())
            return Data(#"{"BackendState":"Running","Peer":{}}"#.utf8)
        })
        await #expect(throws: (any Error).self) {
            try await manager.requestPairing(mini, connection: .init(alias: "mini"), central: URL(string: "https://air.tail.ts.net:8443/wovenmatter")!)
        }
        #expect(await calls.items == ["tailscale"])
    }
    @Test func releaseValidationRejectsArbitraryDownloadsAndComparesBuilds() throws {
        let release = try decodeRelease()
        try release.validate()
        #expect(release.isNewer(than: try CompanionMacInstallation(data: Self.installed)))
        #expect(throws: (any Error).self) { try decodeRelease(url: "https://attacker.example/app.dmg").validate() }
        #expect(throws: (any Error).self) { try decodeRelease(hash: "bad").validate() }
        let same = try CompanionMacInstallation(data: Data("woven-mac-inspection-v1\ninstalled\n0.3.6\n999\n1\n1\narm64\n27.2\n\n\n".utf8))
        #expect(!release.isNewer(than: same))
    }
    @Test func setupIntentExpiresAndCannotContainAnArbitraryEndpoint() throws {
        let now = Date(timeIntervalSince1970: 12345)
        let request = CompanionMacSetupRequest(action: .pair, endpoint: URL(string: "https://air.tail.ts.net:8443/wovenmatter")!, now: now)
        try JSONDecoder().decode(CompanionMacSetupRequest.self, from: Data(request.json().utf8)).validate(now: now)
        #expect(throws: (any Error).self) { try request.validate(now: now.addingTimeInterval(901)) }
        #expect(throws: (any Error).self) { try CompanionMacSetupRequest(action: .pair, endpoint: URL(string: "https://example.com"), now: now).validate(now: now) }
        #expect(throws: (any Error).self) { try CompanionMacSetupRequest(action: .pair, now: now).validate(now: now) }
    }
    @Test func remoteFailuresAreSurfacedRatherThanReportedAsSuccessfulInstalls() async throws {
        let manager = CompanionMacManagement(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, _, _ in
            executable.lastPathComponent == "ssh" ? Data("woven-error:The download checksum did not match.\n".utf8) : Self.status
        })
        do { try await manager.install(mini, connection: .init(alias: "mini"), release: decodeRelease()); Issue.record("Expected checksum failure") }
        catch { #expect(error.localizedDescription == "The download checksum did not match.") }
    }
    @Test func scriptsAreValidBashAndInspectionPreservesEmptyFields() throws {
        for script in [CompanionMacRemoteScripts.inspect, CompanionMacRemoteScripts.pair, CompanionMacRemoteScripts.install] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", "-c", script]; try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        // A missing app must still decode correctly; optional plist fields occupy lines.
        let script = CompanionMacRemoteScripts.inspect
            .replacingOccurrences(of: "/Applications/Woven Matter.app", with: "/nonexistent-woven-test/Woven Matter.app")
            .replacingOccurrences(of: "$HOME/Applications/Woven Matter.app", with: "/nonexistent-woven-test-user/Woven Matter.app")
            .replacingOccurrences(of: "wovenmatter.desktop wovenmatter.device-setup", with: "wovenmatter.fixture.nonexistent wovenmatter.device-setup")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-c", script]
        process.standardOutput = pipe; try process.run()
        let state = try CompanionMacInstallation(data: pipe.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()
        #expect(!state.installed && state.version == nil && state.build == nil)
    }
    private func decodeRelease(url: String = "https://github.com/wovenmatter/wovenmatter/releases/download/v0.3.6/WovenMatter_0.3.6_arm64.dmg", hash: String = String(repeating: "a", count: 64)) throws -> CompanionMacRelease {
        try JSONDecoder().decode(CompanionMacRelease.self, from: JSONSerialization.data(withJSONObject: ["version": "0.3.6", "build": 999, "architecture": "arm64", "minimum_macos": "26.0", "download_url": url, "sha256": hash]))
    }
}
private actor MacManagementCalls {
    var items: [String] = []
    func append(_ value: String) { items.append(value) }
}
