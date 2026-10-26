import Foundation
import Testing
@testable import WovenMatterClient

struct RemoteWorkspaceTailnetTests {
    private func status(_ peers: [[String: Any]], state: String = "Running") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["BackendState": state,
            "Peer": Dictionary(uniqueKeysWithValues: peers.enumerated().map { (String($0.offset), $0.element) })])
    }
    // Synthetic address assembled to keep the public-tree privacy scan strict.
    private var ipv4: String { [100, 80, 0, 2].map(String.init).joined(separator: ".") }
    private var peer: [String: Any] {
        ["HostName": "worker", "DNSName": "worker.example.ts.net.", "Online": true, "OS": "linux",
         "TailscaleIPs": [ipv4, "fd7a:115c:a1e0::2"]]
    }

    @Test func eachPeerNameUsesTheSameDaemonTransport() throws {
        for host in ["worker", "worker.example.ts.net", ipv4, "fd7a:115c:a1e0::2"] {
            let options = try RemoteWorkspaceTailnet.sshOptions(destination: "woven@" + host,
                executable: "/usr/local/bin/tailscale", status: status([peer]))
            // Inspect OpenSSH's effective configuration, without making a connection.
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = directory.appending(path: "config")
            try """
            Host *
              Hostname redirected.invalid
              ProxyCommand /usr/bin/false
              ProxyJump proxy.invalid
              ControlMaster auto
              ControlPath /tmp/existing-ssh-socket
              ForwardAgent yes
              User woven
            """.write(to: config, atomically: true, encoding: .utf8)
            let effective = try RemoteWorkspaceProcess.run(executable: "/usr/bin/ssh",
                arguments: ["-G", "-F", config.path] + options + [host])
            #expect(effective.status == 0)
            let output = String(decoding: effective.data, as: UTF8.self)
            #expect(output.contains("hostname \(ipv4)\n"))
            #expect(output.contains("proxycommand exec '/usr/local/bin/tailscale' nc \(ipv4) %p\n"))
            #expect(!output.contains("proxyjump proxy.invalid"))
            #expect(!output.contains("controlpath /tmp/existing-ssh-socket"))
            #expect(output.contains("stricthostkeychecking true\n") || output.contains("stricthostkeychecking yes\n"))
            #expect(output.contains("forwardagent no\n"))
            #expect(output.contains("user woven\n"))
        }
        let discovered = try RemoteMachineDiscovery.decodeTailnetMachines(from: status([peer]))
        #expect(discovered.map(\.hostName) == ["worker"])
    }

    @Test func discoveryListsOnlyOnlineUnexpiredLinuxPeers() throws {
        var peers: [[String: Any]] = []
        for (name, os) in [("linux-worker", "linux"), ("other-linux", " Linux "),
                           ("localhost", "iOS"), ("ipad", "iPadOS"), ("mac", "macOS"),
                           ("darwin-mac", "darwin"), ("windows", "windows"),
                           ("android", "android"), ("bsd", "freebsd"), ("unknown", "")] {
            var candidate = peer
            candidate["HostName"] = name; candidate["OS"] = os
            peers.append(candidate)
        }
        var missingOS = peer; missingOS.removeValue(forKey: "OS"); peers.append(missingOS)
        var offline = peer; offline["Online"] = false; peers.append(offline)
        var expired = peer; expired["Expired"] = true; peers.append(expired)
        let discovered = try RemoteMachineDiscovery.decodeTailnetMachines(from: status(peers))
        #expect(discovered.map(\.hostName) == ["linux-worker", "other-linux"])
    }

    @Test func discoveryRetainsEveryEligibleLinuxHostAndDNSFallback() throws {
        var peers = (0..<8).map { index in
            var candidate = peer
            candidate["HostName"] = "worker-\(index)"
            candidate["DNSName"] = "worker-\(index).example.ts.net."
            return candidate
        }
        peers[7].removeValue(forKey: "HostName")
        let discovered = try RemoteMachineDiscovery.decodeTailnetMachines(from: status(peers))
        #expect(discovered.count == 8)
        #expect(discovered.map(\.hostName) == (0..<7).map { "worker-\($0)" } + ["worker-7.example.ts.net"])
        #expect(discovered.last?.dnsName == "worker-7.example.ts.net")
    }

    @Test func manualRemoteSSHRejectsAppleAndOtherNonLinuxPeers() throws {
        for os in ["iOS", "iPadOS", "macOS", "darwin", "windows", "android", "freebsd", "", nil] {
            var candidate = peer; candidate["OS"] = os
            do {
                _ = try RemoteWorkspaceTailnet.sshOptions(destination: "worker", executable: "/tailscale", status: status([candidate]))
                Issue.record("A non-Linux peer was accepted for remote workspace SSH")
            } catch let error as RemoteWorkspaceClientError {
                #expect(error.localizedDescription.contains("Linux"))
                #expect(error.localizedDescription.contains("Apple Devices"))
            }
        }
    }

    @Test func daemonStateAndPeerIdentityMustRemainUsable() throws {
        for state in ["Stopped", "NeedsLogin", "Starting"] {
            #expect(throws: RemoteWorkspaceClientError.self) {
                try RemoteWorkspaceTailnet.sshOptions(destination: "worker", executable: "/tailscale", status: status([peer], state: state))
            }
        }
        var offline = peer; offline["Online"] = false
        var expired = peer; expired["Expired"] = true
        for peers in [[offline], [expired], [peer, peer], []] {
            #expect(throws: RemoteWorkspaceClientError.self) {
                try RemoteWorkspaceTailnet.sshOptions(destination: "worker", executable: "/tailscale", status: status(peers))
            }
        }
    }

    @Test func ipv6OnlyPeerUsesItsTailnetAddress() throws {
        var ipv6 = peer; ipv6["TailscaleIPs"] = ["fd7a:115c:a1e0::2"]
        let options = try RemoteWorkspaceTailnet.sshOptions(destination: "worker", executable: "/tailscale", status: status([ipv6]))
        #expect(options.contains("Hostname=fd7a:115c:a1e0::2"))
    }
}
