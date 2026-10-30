import Foundation
import AppKit
import SwiftUI
import Testing
import WovenMatterCompanion
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor
struct MacDeviceSetupModelTests {
    private static func fixtureIP(_ last: Int) -> String { [100, 64, 0, last].map(String.init).joined(separator: ".") }
    private let status = Data(#"{"BackendState":"Running","Peer":{"mini":{"Online":true,"OS":"macOS","DNSName":"mini.tail.ts.net.","HostName":"Mac mini","TailscaleIPs":["\#(Self.fixtureIP(2))"]}}}"#.utf8)
    private let empty = Data(#"{"BackendState":"Running","Peer":{}}"#.utf8)

    @Test func emptySearchCompletesAndShowsNoMacsInsteadOfAnIdleUnsearchedState() async {
        let input = empty
        let model = MacDeviceSetupModel(management: .init(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { _, _, _ in input }), getRelease: { throw MacDeviceSetupError("Offline release feed") })
        #expect(!model.searched)
        await model.discover()
        #expect(model.searched && !model.searching && model.rows.isEmpty && model.error == nil)
        #expect(model.releaseError != nil)
    }
    @Test func uninspectableMacStaysVisibleAndIsNotClassifiedAsMissing() async {
        let input = status
        let model = MacDeviceSetupModel(management: .init(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, _, _ in
            if executable.lastPathComponent == "ssh" { throw MacDeviceSetupError("SSH fixture denied") }
            return input
        }), getRelease: { throw MacDeviceSetupError("No release fixture") })
        await model.discover()
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.installation == nil)
        #expect(model.rows.first?.error != nil)
        #expect(model.error == nil)
    }
    @Test func stoppedInstalledMacRetainsVersionWithoutAnyServiceProbe() async {
        let input = status
        let model = MacDeviceSetupModel(management: .init(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, _, _ in
            executable.lastPathComponent == "ssh"
                ? Data("woven-mac-inspection-v1\ninstalled\n0.3.2\n900\n\n0\narm64\n27.2\n\n\n".utf8) : input
        }), getRelease: { throw MacDeviceSetupError("No release fixture") })
        await model.discover()
        #expect(model.rows.first?.installation?.version == "0.3.2")
        #expect(model.rows.first?.installation?.running == false)
    }
    @Test func aPreviousPairingResultCannotFinishANewAttempt() async throws {
        let fixture = SetupResultFixture(status: status)
        let model = MacDeviceSetupModel(management: .init(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, args, _ in
            try await fixture.run(executable: executable, args: args)
        }), getRelease: { throw MacDeviceSetupError("No release fixture") }, pollDelay: {})
        await model.discover()
        let row = try #require(model.rows.first)
        await model.perform(.pair, row: row, central: URL(string: "https://central.tail.ts.net:8443/wovenmatter")!)
        #expect(row.error == nil)
        #expect(row.message == "Current request accepted")
        #expect(await fixture.polls == 2)
        let prompt = DeviceSetupConfirmation(row: row, action: .pair, sendsInvitation: false)
        #expect(prompt.message(version: nil, central: true, snapshot: true).contains("isolated snapshot database"))
    }

    @Test func deviceRowsRenderAtNarrowAndWideSettingsInEveryTheme() async throws {
        _ = NSApplication.shared
        let input = Data(#"{"BackendState":"Running","Peer":{"mini":{"Online":true,"OS":"macOS","DNSName":"mini.tail.ts.net.","HostName":"Studio Mac mini","TailscaleIPs":["\#(Self.fixtureIP(2))"]},"fresh":{"Online":true,"OS":"macOS","DNSName":"fresh.tail.ts.net.","HostName":"New MacBook Pro","TailscaleIPs":["\#(Self.fixtureIP(3))"]},"offline":{"Online":false,"OS":"macOS","DNSName":"offline.tail.ts.net.","HostName":"Office Mac","TailscaleIPs":["\#(Self.fixtureIP(4))"]}}}"#.utf8)
        let release = try JSONDecoder().decode(CompanionMacRelease.self, from: Data("""
            {"version":"0.3.6","build":999,"architecture":"arm64","minimum_macos":"26.0","device_setup_version":1,"download_url":"https://github.com/wovenmatter/wovenmatter/releases/download/v0.3.6/WovenMatter_0.3.6_arm64.dmg","sha256":"\(String(repeating: "a", count: 64))"}
            """.utf8))
        let devices = MacDeviceSetupModel(management: .init(executable: URL(fileURLWithPath: "/fixture/Tailscale"), run: { executable, args, _ in
            guard executable.lastPathComponent == "ssh" else { return input }
            return Data((args.contains("fresh")
                ? "woven-mac-inspection-v1\nmissing\n\n\n\n0\narm64\n27.2\n\n\n"
                : "woven-mac-inspection-v1\ninstalled\n0.3.2\n906\n\n0\narm64\n27.2\n\n\n").utf8)
        }), getRelease: { release })
        await devices.discover()
        let suite = "mac-device-layout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let application = ApplicationModel(applicationDefaults: defaults, startsAutomatically: false, ownsExecutionOverride: false)
        let pairing = CompanionMacPairingController(identity: { .init(deviceID: UUID().uuidString, deviceName: "Fixture", metadata: .init(kind: .mac)) }, onPaired: { _, _ in })
        for theme in DashboardTheme.allCases {
            for width: CGFloat in [440, 920] {
                let view = SettingsPage(title: "Apple Devices") {
                    SettingsCard(title: "Find devices", detail: "Find other Macs on your Tailscale network, even when Woven Matter is closed.") {
                        MacTailnetDiscoveryView(devices: devices, pairing: pairing, host: application.companionHost, isCentral: true, canPairWithCentral: false)
                    }
                }.background(theme.palette.workspace).environment(\.dashboardTheme, theme).preferredColorScheme(theme.colorScheme)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.setFrameSize(NSSize(width: width, height: 820))
                for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                if let folder = ProcessInfo.processInfo.environment["WOVENMATTER_DEVICE_PREVIEWS"] {
                    let output = URL(fileURLWithPath: folder)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try png.write(to: output.appendingPathComponent("\(theme.rawValue)-\(Int(width)).png"))
                }
                window.contentView = nil; window.close()
            }
        }
    }
}

private actor SetupResultFixture {
    let status: Data
    var requestID: UUID?
    var polls = 0
    init(status: Data) { self.status = status }
    func run(executable: URL, args: [String]) throws -> Data {
        guard executable.lastPathComponent == "ssh" else { return status }
        let command = args.last ?? ""
        if command.contains("woven-mac-inspection-v1") {
            var result = ""
            if let requestID {
                polls += 1
                result = try CompanionMacSetupStatus(requestID: polls == 1 ? UUID() : requestID,
                    phase: polls == 1 ? .paired : .waiting,
                    message: polls == 1 ? "Old request succeeded" : "Current request accepted").json()
            }
            return Data("woven-mac-inspection-v1\ninstalled\n0.3.6\n999\n1\n0\narm64\n27.2\n\(result)\n\n".utf8)
        }
        let delimiter = try #require(command.range(of: " -- '", options: .backwards))
        let json = String(command[delimiter.upperBound...].dropLast())
        requestID = try JSONDecoder().decode(CompanionMacSetupRequest.self, from: Data(json.utf8)).id
        return Data()
    }
}
