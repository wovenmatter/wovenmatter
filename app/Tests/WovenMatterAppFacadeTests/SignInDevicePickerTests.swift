import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// Settings → Subscriptions & API Keys' "Sign in on" picker and the links that open it.
@Suite("Sign in on picker", .serialized)
@MainActor
struct SignInDevicePickerTests {
    private let workspace = "b0000000-0000-4000-8000-000000000000"
    private var devices: [SignInDevice] {
        [
            .init(id: SignInDevice.linuxID(workspace), kind: .linux, name: "workstation-home-1", runsBots: true,
                  memberID: "linux-member", workspaceID: workspace),
            .init(id: SignInDevice.macID("mac-b"), kind: .mac, name: "James's Mac mini", runsBots: false, memberID: "mac-b"),
            .init(id: SignInDevice.macID("mac-a"), kind: .mac, name: "James's MacBook Air", runsBots: true, memberID: "mac-a"),
            .init(id: SignInDevice.localID, kind: .thisMac, name: "James's Mac Studio", runsBots: false, memberID: "this-mac"),
        ]
    }

    /// Devices are named as people read them on the tailnet: Tailscale's host name,
    /// matched by DNS name, and this Mac's own (`Self`).
    @Test func devicesAreNamedByTheirTailnetHostName() {
        let status = Data("""
        {"Self":{"HostName":"James's Mac Studio","DNSName":"jamess-mac-studio.tail1234.ts.net."},
         "Peer":{"a":{"HostName":"James's MacBook Air","DNSName":"jamess-macbook-air.tail1234.ts.net."},
                 "b":{"HostName":"workstation-home-1","DNSName":"workstation-home-1.tail1234.ts.net."},
                 "c":{"DNSName":"no-host-name.tail1234.ts.net."}}}
        """.utf8)
        let names = RemoteWorkspaceTailnet.hostNames(status: status)
        #expect(names.this == "James's Mac Studio")
        #expect(names.name(forHost: "jamess-macbook-air.tail1234.ts.net") == "James's MacBook Air")
        #expect(names.name(forHost: "Workstation-Home-1.tail1234.ts.net.") == "workstation-home-1")
        #expect(names.name(forHost: "no-host-name.tail1234.ts.net") == nil)
        #expect(SignInDevice.tailnetName("no-host-name.tail1234.ts.net") == "no-host-name")
        #expect(RemoteWorkspaceTailnet.hostNames(status: Data("not json".utf8)) == .init())
    }

    @Test func listsThisMacThenOtherMacsThenWorkspacesAndMarksBots() {
        let options = SignInDevicePicker.options(devices, selected: SignInDevice.localID)
        #expect(options == [SignInDevice.localID, SignInDevice.macID("mac-b"), SignInDevice.macID("mac-a"), SignInDevice.linuxID(workspace)])
        let labels = options.map { SignInDevicePicker.label($0, devices: devices) }
        #expect(labels == ["Local workspace (James's Mac Studio)", "James's Mac mini", "James's MacBook Air · Bots", "workstation-home-1 · Bots"])
        #expect(!options.contains("global"))
        #expect(!labels.contains("All workspaces"))
        #expect(SignInDevicePicker.title == "Sign in on")
        #expect(SignInDevicePicker.pageDetail == "Used by Pi Durable and bots on the selected device. Codex, Claude Code, Grok Build, and OpenCode sign in on their own pages. Usage limits shows the accounts signed in on this device.")
    }

    @Test func keepsTheSelectedDeviceWhileTheListLoads() {
        let mac = SignInDevice.macID("mac-c")
        #expect(SignInDevicePicker.options([], selected: SignInDevice.localID) == [SignInDevice.localID])
        #expect(SignInDevicePicker.options([], selected: mac) == [SignInDevice.localID, mac])
        #expect(SignInDevicePicker.label(SignInDevice.localID, devices: []) == "Local workspace")
        #expect(SignInDevicePicker.label(mac, devices: []) { $0 == mac ? "office-mac" : nil } == "office-mac")
    }

    @Test func pageLinksOpenOnTheirDevice() {
        // Scopes from older links and the Pi Durable page name the device that holds their sign-ins.
        #expect(SignInDevicePicker.device(forPage: "global") == SignInDevice.localID)
        #expect(SignInDevicePicker.device(forPage: "local") == SignInDevice.localID)
        #expect(SignInDevicePicker.device(forPage: workspace.uppercased()) == SignInDevice.linuxID(workspace))
        #expect(SignInDevicePicker.device(forPage: SignInDevice.macID("mac-a")) == SignInDevice.macID("mac-a"))
        #expect(SignInDevicePicker.device(forPage: SignInDevice.linuxID(workspace)) == SignInDevice.linuxID(workspace))
        #expect(ManageAccountsLink().device == SignInDevice.localID)
    }

    @Test func aBotOpensTheDeviceItRunsOn() {
        #expect(SignInDevicePicker.device(forBotMachine: "LINUX-MEMBER", machines: [], devices: devices) == SignInDevice.linuxID(workspace))
        #expect(SignInDevicePicker.device(forBotMachine: "mac-a", machines: [], devices: devices) == SignInDevice.macID("mac-a"))
        #expect(SignInDevicePicker.device(forBotMachine: "this-mac", machines: [], devices: devices) == SignInDevice.localID)
        // Before the device list has loaded, the bots machine itself says where it is.
        var linux = BotMachine(id: "linux-member", name: "workstation", kind: .linux, state: .ready)
        linux.workspaceID = workspace
        let machines = [BotMachine(id: "this-mac", name: "studio", kind: .thisMac, state: .ready),
                        BotMachine(id: "Mac-A", name: "macbook-air", kind: .mac, state: .ready), linux]
        #expect(SignInDevicePicker.device(forBotMachine: "linux-member", machines: machines, devices: []) == SignInDevice.linuxID(workspace))
        #expect(SignInDevicePicker.device(forBotMachine: "Mac-A", machines: machines, devices: []) == SignInDevice.macID("mac-a"))
        #expect(SignInDevicePicker.device(forBotMachine: "this-mac", machines: machines, devices: []) == SignInDevice.localID)
    }

    @Test func choosingEachKindOfDeviceSelectsIt() async throws {
        let keychain = SignInKeychainFixture()
        let model = KeychainAccess.$testOperations.withValue(keychain.operations) { DefaultAgentSettingsModel() }
        let host = FakeLinuxSignInHost(), id = try #require(UUID(uuidString: workspace))
        model.memberRoutes = { _ in host }
        var peers: [String] = []
        model.peerTransport = { member in
            peers.append(member)
            return { _, _ in throw DefaultAgentError.message("Update Woven Matter on mac-a to manage its sign-ins from here.") }
        }
        KeychainAccess.$testOperations.withValue(keychain.operations) {
            SignInDevicePicker.select(SignInDevice.linuxID(id), on: model, remote: [])
            #expect(model.device == SignInDevice.linuxID(workspace))
            #expect(model.scope == workspace)

            SignInDevicePicker.select(SignInDevice.macID("mac-a"), on: model, remote: [])
            #expect(model.device == SignInDevice.macID("mac-a"))
            #expect(model.forwardsToPeer)
            #expect(peers == ["mac-a"])

            // This Mac comes back with the chat settings for All workspaces, as before.
            SignInDevicePicker.select(SignInDevice.localID, on: model, remote: [])
            #expect(model.device == SignInDevice.localID)
            #expect(model.scope == "global")
            #expect(!model.forwardsToPeer)
        }
        model.cancel()
        #expect(keychain.stored.isEmpty)
    }

    /// The page offers only the selected device's own accounts: nothing about shared
    /// accounts, falling back to them, or resetting a workspace to them remains.
    @Test func noSharedAccountControlRemains() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Views")
        for file in ["SettingsAccountsView.swift", "SettingsConnectionsView.swift", "LocalModelServerConnections.swift"] {
            let source = try String(contentsOf: views.appending(path: file), encoding: .utf8)
            for phrase in ["Use shared sign-in", "Manage shared", "shared accounts", "Shared accounts", "Shared fallback",
                           "Reset workspace credentials", "Account recovery", "across workspaces", "receive shared",
                           "sharedAccounts", "SettingsWorkspacePicker", "onManageShared", "Accounts for"] {
                #expect(!source.contains(phrase), "\(file) still contains \(phrase)")
            }
        }
    }
}
