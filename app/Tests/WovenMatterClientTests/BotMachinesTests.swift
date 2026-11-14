import Foundation
import Testing
@testable import WovenMatterClient

struct BotMachinesTests {
    private let gib = BotResourceSettings.gib
    private func capacity(memory: Int64 = 16, disk: Int64 = 500, free: Int64 = 200, used: Int64? = nil) -> BotMachineCapacity {
        BotMachineCapacity(memoryBytes: memory * gib, diskTotalBytes: disk * gib, diskFreeBytes: free * gib,
                           diskUsedByBotsBytes: used.map { $0 * gib })
    }

    // MARK: Resources

    @Test func defaultsAreEightGigabytePoolFourPerBotFiftyDisk() {
        let defaults = BotResourcePolicy.defaults(for: capacity())
        #expect(defaults == BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 50 * gib))
    }

    @Test func defaultsFitASmallMachine() {
        let small = BotResourcePolicy.defaults(for: capacity(memory: 6, disk: 32, free: 10))
        #expect(small.poolBytes == 6 * gib)
        #expect(small.perBotBytes == 4 * gib)
        #expect(small.diskBytes == 32 * gib)
    }

    @Test func poolChoicesRunFromOneGigabyteToDeviceMemory() {
        let choices = BotResourcePolicy.poolChoices(capacity(memory: 16))
        #expect(choices.first == gib)
        #expect(choices.last == 16 * gib)
        #expect(choices.count == 16)
    }

    @Test func perBotChoicesStopAtThePoolOrDeviceMemory() {
        #expect(BotResourcePolicy.perBotChoices(pool: 6 * gib, capacity()).last == 6 * gib)
        #expect(BotResourcePolicy.perBotChoices(pool: nil, capacity(memory: 32)).last == 32 * gib)
    }

    @Test func diskChoicesEndAtTheDiskSize() {
        let choices = BotResourcePolicy.diskChoices(capacity(disk: 256))
        #expect(choices.last == 256 * gib)
        #expect(choices.contains(50 * gib))
        #expect(!choices.contains(500 * gib))
    }

    @Test func validationClampsEveryValueIntoItsRange() {
        let settings = BotResourceSettings(poolBytes: 64 * gib, perBotBytes: 32 * gib, diskBytes: 2_000 * gib)
        let fitted = BotResourcePolicy.validated(settings, capacity(memory: 16, disk: 500))
        #expect(fitted.poolBytes == 16 * gib)
        #expect(fitted.perBotBytes == 16 * gib)
        #expect(fitted.diskBytes == 500 * gib)
        let tiny = BotResourcePolicy.validated(BotResourceSettings(poolBytes: 1, perBotBytes: 1, diskBytes: 1), capacity())
        #expect(tiny == BotResourceSettings(poolBytes: gib, perBotBytes: gib, diskBytes: gib))
    }

    @Test func noCapStaysNoCap() {
        let none = BotResourceSettings(poolBytes: nil, perBotBytes: nil, diskBytes: nil)
        #expect(BotResourcePolicy.validated(none, capacity()) == none)
        let perBot = BotResourcePolicy.validated(BotResourceSettings(poolBytes: nil, perBotBytes: 64 * gib, diskBytes: nil), capacity(memory: 16))
        #expect(perBot.perBotBytes == 16 * gib)
    }

    @Test func loweringDiskStopsAtWhatBotsAlreadyUse() {
        let fitted = BotResourcePolicy.validated(BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 10 * gib),
                                                 capacity(used: 30))
        #expect(fitted.diskBytes == 30 * gib)
    }

    @Test func warnsWhenThePoolLeavesTheDeviceLessThanFourGigabytes() {
        #expect(BotResourcePolicy.warnings(.defaults, capacity(memory: 16)).isEmpty)
        let tight = BotResourcePolicy.warnings(BotResourceSettings(poolBytes: 14 * gib, perBotBytes: 4 * gib, diskBytes: 50 * gib), capacity(memory: 16))
        #expect(tight == [.poolLeavesLittleMemory(leftBytes: 2 * gib)])
        let uncapped = BotResourcePolicy.warnings(BotResourceSettings(poolBytes: nil, perBotBytes: 4 * gib, diskBytes: 50 * gib), capacity())
        #expect(uncapped.contains(.poolLeavesLittleMemory(leftBytes: 0)))
    }

    @Test func warnsWhenTheDiskCapExceedsFreeSpace() {
        let over = BotResourcePolicy.warnings(BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 300 * gib), capacity(free: 200))
        #expect(over == [.diskCapExceedsFree(freeBytes: 200 * gib)])
        // What bots already store counts as room they have.
        let counted = BotResourcePolicy.warnings(BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 220 * gib), capacity(free: 200, used: 30))
        #expect(counted.isEmpty)
        #expect(BotResourcePolicy.warnings(BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: nil), capacity())
            .contains(.diskCapExceedsFree(freeBytes: 200 * gib)))
    }

    @Test func formatsBytesForPeople() {
        #expect(BotResourcePolicy.format(nil) == "No cap")
        #expect(BotResourcePolicy.format(8 * gib) == "8 GB")
        #expect(BotResourcePolicy.format(gib + gib / 2) == "1.5 GB")
        #expect(BotResourcePolicy.format(2_000 * gib) == "2 TB")
    }

    @Test func noCapEncodesAsExplicitNull() throws {
        let data = try JSONEncoder().encode(BotResourceSettings(poolBytes: nil, perBotBytes: 4 * gib, diskBytes: nil))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == ["diskBytes", "perBotBytes", "poolBytes"])
        #expect(object["poolBytes"] is NSNull)
        #expect(try JSONDecoder().decode(BotResourceSettings.self, from: data).perBotBytes == 4 * gib)
    }

    // MARK: Machines and versions

    private func machine(_ id: String, kind: BotMachine.Kind, app: String? = "1.4.0", runtime: String? = "0.2.0",
                         state: BotMachine.State = .ready) -> BotMachine {
        BotMachine(id: id, name: id, kind: kind, state: state, versions: .init(app: app, runtime: runtime, protocol: 1))
    }

    @Test func remoteStatusBecomesAMachineAndFlagsAVersionMismatch() {
        let status = BotsRemoteStatus(machine: .init(deviceID: "D1", name: "box", kind: "linux"), enabled: true, state: "ready",
                                      versions: .init(app: "1.3.0", runtime: "0.2.0", protocol: 1))
        let socket = BotSocketEndpoint(url: URL(string: "ws://127.0.0.1:4000/v1/bots/ws")!, bearer: "secret")
        let mismatched = status.machine(kind: .linux, socket: socket, thisMacVersion: "1.4.0")
        #expect(mismatched.state == .needsUpdate)
        #expect(mismatched.message?.contains("Settings → Updates") == true)
        let matched = status.machine(kind: .linux, socket: socket, thisMacVersion: "1.3.0")
        #expect(matched.state == .ready && matched.socket == socket)
        var off = status; off.enabled = false; off.state = "off"
        #expect(off.machine(kind: .linux, socket: socket, thisMacVersion: "1.3.0").socket == nil)
    }

    /// What remote/src/bots-service.mjs answers: the shared fields plus its own engine detail.
    @Test func linuxServerStatusDecodes() throws {
        let body = """
        {"machine":{"deviceID":"0b6f8c2e-6a51-4f7e-9d8a-2f9f6c1d3e4a","name":"box","kind":"linux"},"enabled":true,
         "state":"starting","message":"Waiting for the bot engine.","versions":{"app":null,"runtime":"0.1.0","protocol":1},
         "resources":{"poolBytes":8589934592,"perBotBytes":4294967296,"diskBytes":null},
         "capacity":{"memoryBytes":34359738368,"diskTotalBytes":1000000000000,"diskFreeBytes":500000000000,"diskUsedByBotsBytes":null},
         "paused":false,"workspaceEnabled":false,"runtimeAvailable":true,"engine":{"installed":false},"runtime":null,"settings":{}}
        """
        let status = try JSONDecoder().decode(BotsRemoteStatus.self, from: Data(body.utf8))
        #expect(status.resources == .init(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: nil))
        #expect(status.capacity?.memoryBytes == 32 * gib && status.paused == false)
        // No app version on Linux, so it never reads as a mismatch.
        #expect(status.machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0").state == .starting)
    }

    @Test func socketDescriptionNeverPrintsTheBearer() {
        let socket = BotSocketEndpoint(url: URL(string: "wss://mac.tail.ts.net/wovenmatter/v1/bots/ws")!, bearer: "secret-token")
        #expect(!String(describing: socket).contains("secret-token"))
    }

    @Test func versionReportNamesOutdatedPartsAndStoppedSync() {
        let machines = [machine("this", kind: .thisMac), machine("box", kind: .linux, app: "1.3.0"), machine("mini", kind: .mac, runtime: "0.1.0")]
        let report = BotVersionReport(thisMacVersion: "1.4.0", machines: machines)
        #expect(report.outdated.map(\.id) == ["box", "bots:mini"])
        #expect(report.message?.contains("Update everything in Settings → Updates") == true)
        let stopped = BotVersionReport(thisMacVersion: "1.4.0", machines: [machine("this", kind: .thisMac)],
                                       syncErrors: ["Update both Macs to the same Woven Matter version before synchronizing."])
        #expect(stopped.syncStopped && stopped.needsUpdate)
        #expect(stopped.message?.contains("sync stopped") == true)
        #expect(!BotVersionReport(thisMacVersion: "1.4.0", machines: [machine("this", kind: .thisMac)]).needsUpdate)
        let both = BotVersionReport(thisMacVersion: "1.4.0",
                                    machines: [machine("this", kind: .thisMac, runtime: "0.2.0"), machine("box", kind: .linux, app: "1.3.0", runtime: "0.1.0")])
        #expect(both.outdated.map(\.id) == ["box", "bots:box"])
        #expect(both.message?.hasPrefix("box runs a different version.") == true)
    }

    @Test func updateEverythingUpdatesOthersThenBotsThenThisMacLast() {
        let machines = [machine("this", kind: .thisMac), machine("box", kind: .linux, app: "1.3.0"),
                        machine("same", kind: .linux), machine("mini", kind: .mac, app: "1.5.0"),
                        machine("gone", kind: .linux, app: "1.0.0", state: .unreachable)]
        let steps = DeviceUpdatePlan.steps(machines: machines, thisMacVersion: "1.4.0")
        #expect(steps.first == .linuxHost(id: "box", name: "box"))
        #expect(!steps.contains(.linuxHost(id: "same", name: "same")))
        #expect(!steps.contains(.linuxHost(id: "gone", name: "gone")))
        // A Mac already newer than this one is not downgraded; this Mac catches up instead.
        #expect(!steps.contains(.mac(id: "mini", name: "mini")))
        #expect(steps.contains(.bots(machineID: "this", name: "This Mac")))
        #expect(steps.last == .thisMacApp)
        #expect(!DeviceUpdatePlan.steps(machines: [machine("this", kind: .thisMac)], thisMacVersion: "1.4.0").contains(.thisMacApp))
    }

    @Test func aLinuxHostIsJudgedByItsReleaseFingerprint() {
        let ours = String(repeating: "a", count: 64), theirs = String(repeating: "b", count: 64)
        func status(app: String?, fingerprint: String?) -> BotsRemoteStatus {
            BotsRemoteStatus(machine: .init(deviceID: "D1", name: "box", kind: "linux"), enabled: true, state: "ready",
                             versions: .init(app: app, runtime: "0.2.0", protocol: 1, fingerprint: fingerprint, librarySchema: "s1"))
        }
        // Same version name, different release (a development build): still out of date.
        let other = status(app: "1.4.0", fingerprint: theirs).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0", expectedHostFingerprint: ours)
        #expect(other.state == .needsUpdate)
        #expect(other.message?.contains("different Woven host release") == true)
        // The exact release this Mac installs is current, whatever version it names.
        #expect(status(app: "1.3.9", fingerprint: ours).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0",
                                                                  expectedHostFingerprint: ours).state == .ready)
        // A host too old to report its release is out of date.
        #expect(status(app: nil, fingerprint: nil).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0",
                                                             expectedHostFingerprint: ours).state == .needsUpdate)
        // Without bundled host sources this Mac can only compare version names.
        #expect(status(app: "1.4.0", fingerprint: theirs).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0").state == .ready)
        // A library whose paired-library schema differs cannot sync, whatever the release says.
        let schema = status(app: "1.4.0", fingerprint: ours).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0",
                                                                    expectedHostFingerprint: ours, thisMacLibrarySchema: "s2")
        #expect(schema.state == .needsUpdate && schema.message?.contains("library format") == true)
        #expect(status(app: "1.4.0", fingerprint: ours).machine(kind: .linux, socket: nil, thisMacVersion: "1.4.0",
                                                                  expectedHostFingerprint: ours, thisMacLibrarySchema: "s1").state == .ready)

        var stale = machine("box", kind: .linux, app: "1.4.0", state: .needsUpdate); stale.versions.fingerprint = theirs
        var current = machine("same", kind: .linux, app: "1.3.0"); current.versions.fingerprint = ours
        let steps = DeviceUpdatePlan.steps(machines: [machine("this", kind: .thisMac), stale, current], thisMacVersion: "1.4.0")
        #expect(steps.contains(.linuxHost(id: "box", name: "box")))
        #expect(!steps.contains(.linuxHost(id: "same", name: "same")))
        #expect(BotVersionReport(thisMacVersion: "1.4.0", machines: [stale]).outdated.map(\.current) == ["release bbbbbbbb"])
    }

    @Test func thisMacUpdatesFirstWhenANewerReleaseIsPublished() {
        let machines = [machine("this", kind: .thisMac), machine("box", kind: .linux, app: "1.3.0"), machine("mini", kind: .mac, app: "1.3.0")]
        // Linux hosts can only get this Mac's release, so this Mac goes first, alone.
        #expect(DeviceUpdatePlan.steps(machines: machines, thisMacVersion: "1.4.0", latestVersion: "1.5.0") == [.thisMacApp])
        // On the newest release, the rest of the fleet follows, and this Mac has nothing to do.
        let current = DeviceUpdatePlan.steps(machines: machines, thisMacVersion: "1.5.0", latestVersion: "1.5.0")
        #expect(current.first == .linuxHost(id: "box", name: "box"))
        #expect(current.contains(.mac(id: "mini", name: "mini")) && !current.contains(.thisMacApp))
        // An unknown newest release falls back to matching this Mac.
        #expect(DeviceUpdatePlan.steps(machines: machines, thisMacVersion: "1.4.0").first == .linuxHost(id: "box", name: "box"))
        #expect(DeviceUpdatePlan.thisMacIsBehind(thisMacVersion: "1.4.0", latestVersion: "1.10.0"))
        #expect(!DeviceUpdatePlan.thisMacIsBehind(thisMacVersion: "1.10.0", latestVersion: "1.9.0"))
        #expect(!DeviceUpdatePlan.thisMacIsBehind(thisMacVersion: "1.4.0", latestVersion: nil))
    }

    @Test func aMacIsCurrentOnThisMacsVersionOrNewer() {
        #expect(DeviceUpdatePlan.macIsCurrent(machine("mini", kind: .mac, app: "1.4.0"), thisMacVersion: "1.4.0"))
        #expect(DeviceUpdatePlan.macIsCurrent(machine("mini", kind: .mac, app: "1.5.0"), thisMacVersion: "1.4.0"))
        #expect(!DeviceUpdatePlan.macIsCurrent(machine("mini", kind: .mac, app: "1.3.0"), thisMacVersion: "1.4.0"))
        #expect(!DeviceUpdatePlan.macIsCurrent(machine("mini", kind: .mac, app: nil), thisMacVersion: "1.4.0"))
    }

    @Test func updateEverythingUpdatesAMacsVMBeforeItsBots() {
        let steps = DeviceUpdatePlan.steps(machines: [machine("this", kind: .thisMac), machine("mini", kind: .mac), machine("box", kind: .linux)],
                                        thisMacVersion: "1.4.0")
        let engine = steps.firstIndex(of: .engine(machineID: "this", name: "This Mac"))
        let bots = steps.firstIndex(of: .bots(machineID: "this", name: "This Mac"))
        #expect(engine != nil && bots != nil && engine! < bots!)
        #expect(steps.contains(.engine(machineID: "mini", name: "mini")))
        // A Linux host's engine updates with the host.
        #expect(!steps.contains(.engine(machineID: "box", name: "box")))
    }

    @Test func linuxStatusWithReleaseAndEngineUpdateFieldsDecodes() throws {
        let body = """
        {"machine":{"deviceID":"D1","name":"box","kind":"linux"},"enabled":true,"state":"ready",
         "versions":{"app":"1.4.0","runtime":"0.1.0","protocol":1,"fingerprint":"\(String(repeating: "c", count: 64))","librarySchema":null},
         "paused":false,"updating":true,"engineUpdateFailure":"rolled back"}
        """
        let status = try JSONDecoder().decode(BotsRemoteStatus.self, from: Data(body.utf8))
        #expect(status.versions.fingerprint?.count == 64 && status.versions.librarySchema == nil)
        let machine = status.machine(kind: .mac, socket: nil, thisMacVersion: "1.4.0")
        #expect(machine.updating && machine.engineUpdateFailure == "rolled back")
    }

    @Test func discoveryIncludesMacsOnlyWhenAsked() throws {
        let status = Data(#"""
        {"BackendState":"Running","Self":{"DNSName":"me.tail.ts.net."},"Peer":{
          "a":{"HostName":"box","DNSName":"box.tail.ts.net.","OS":"linux","Online":true},
          "b":{"HostName":"mini","DNSName":"mini.tail.ts.net.","OS":"macOS","Online":true},
          "c":{"HostName":"phone","DNSName":"phone.tail.ts.net.","OS":"iOS","Online":true},
          "d":{"HostName":"old","DNSName":"old.tail.ts.net.","OS":"macOS","Online":false}}}
        """#.utf8)
        #expect(try RemoteMachineDiscovery.decodeTailnetMachines(from: status).map(\.hostName) == ["box"])
        let all = try RemoteMachineDiscovery.decodeTailnetMachines(from: status, includeMacs: true)
        #expect(all.map(\.hostName) == ["box", "mini"])
        #expect(all.map(\.system) == ["linux", "macOS"])
    }
}
