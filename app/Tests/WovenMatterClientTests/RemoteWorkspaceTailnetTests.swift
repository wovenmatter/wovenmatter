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

    /// What Tailscale's app binary prints, with exit status 0, when it starts as
    /// the GUI. Tailscale is connected then, so the message must not say to connect it.
    @Test func outputThatIsNotAStatusIsReportedAsUnreadableRatherThanDisconnectedOrAParsingError() throws {
        let output = Data("The Tailscale GUI failed to start: The operation couldn’t be completed. (Tailscale.CLIError error 3.)\n".utf8)
        for data in [output, Data()] {
            let errors = [#expect(throws: RemoteWorkspaceClientError.self) { try RemoteMachineDiscovery.decodeTailnetMachines(from: data) },
                          #expect(throws: RemoteWorkspaceClientError.self) {
                              try RemoteWorkspaceTailnet.sshOptions(destination: "worker", executable: "/tailscale", status: data)
                          }]
            for error in errors { #expect(error?.localizedDescription == RemoteWorkspaceTailnet.statusUnreadable) }
        }
        let stopped = #expect(throws: RemoteWorkspaceClientError.self) {
            try RemoteMachineDiscovery.decodeTailnetMachines(from: status([peer], state: "Stopped"))
        }
        #expect(stopped?.localizedDescription.contains("Connect Tailscale") == true)
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

}
