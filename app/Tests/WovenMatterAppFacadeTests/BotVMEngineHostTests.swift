import Foundation
import Testing
import WovenMatterClient
@testable import WovenMatterAppFacade

/// A scripted Woven VM helper: each `status()` returns the next scripted reply (the last one
/// repeats), the way the helper's control socket would while it downloads, boots and updates.
private actor ScriptedVM: BotVMControl {
    nonisolated let engineSocket = URL(fileURLWithPath: "/private/tmp/wovenmatter-vm-test/docker.sock")
    private var script: [Result<WovenVMStatus, WovenVMError>]
    private(set) var applied: [WovenVMResources] = []
    private(set) var updates = 0
    private(set) var stops = 0
    private(set) var ensures = 0
    var afterUpdate: [Result<WovenVMStatus, WovenVMError>] = []

    init(_ script: [Result<WovenVMStatus, WovenVMError>]) { self.script = script }

    func setScript(_ value: [Result<WovenVMStatus, WovenVMError>]) { script = value }
    func setAfterUpdate(_ value: [Result<WovenVMStatus, WovenVMError>]) { afterUpdate = value }

    private func next() throws -> WovenVMStatus {
        let reply = script.count > 1 ? script.removeFirst() : script[0]
        return try reply.get()
    }

    func ensureRunning() async throws -> WovenVMStatus { ensures += 1; return try next() }
    func status() async throws -> WovenVMStatus { try next() }
    func applyResources(_ resources: WovenVMResources) async throws -> WovenVMStatus {
        applied.append(resources)
        return try next()
    }
    func update() async throws -> WovenVMStatus {
        updates += 1
        let current = try next()
        if !afterUpdate.isEmpty { script = afterUpdate }
        return current
    }
    func stop() async throws { stops += 1 }
}

private func vm(_ phase: WovenVMPhase, detail: String? = nil, failure: String? = nil, progress: Double? = nil,
                used: UInt64? = nil, restartPending: Bool = false, updateFailure: String? = nil) -> Result<WovenVMStatus, WovenVMError> {
    var status = WovenVMStatus(phase: phase, detail: detail, failure: failure, progress: progress,
                               engineSocket: "/private/tmp/wovenmatter-vm-test/docker.sock",
                               resources: .init(hostMemoryBytes: 32 << 30, hostDiskTotalBytes: 1 << 40, hostDiskFreeBytes: 500 << 30,
                                                vmMemoryBytes: 8 << 30, vmDiskCapBytes: 50 << 30, vmDiskAllocatedBytes: 3 << 30,
                                                guestDiskUsedBytes: used, restartPending: restartPending))
    status.updateFailure = updateFailure
    return .success(status)
}

@MainActor @Suite(.serialized)
struct BotVMEngineHostTests {
    private let gib = BotResourceSettings.gib

    @Test func firstStartReportsDownloadAndSetupProgressAndSizesTheVM() async throws {
        let scripted = ScriptedVM([vm(.stopped), vm(.downloading, detail: "Downloading ubuntu.img", progress: 0.42),
                                   vm(.downloading, progress: 0.42), vm(.preparing, detail: "Preparing the VM disk"),
                                   vm(.booting, detail: "Starting the VM"), vm(.provisioning, detail: "Installing Docker Engine"), vm(.ready)])
        let engine = WovenVMBotEngineHost(vm: scripted, pollInterval: .milliseconds(1))
        var seen: [BotEngineStatus] = []
        engine.onStatusChange = { seen.append($0) }
        let status = try await engine.ensureRunning(resources: .init(poolBytes: 6 * gib, perBotBytes: 2 * gib, diskBytes: 80 * gib))
        #expect(status == .init(state: .running, socketPath: "/private/tmp/wovenmatter-vm-test/docker.sock", message: nil))
        // The pool is the VM's memory and the disk cap its disk; per-bot RAM stays with the runtime.
        #expect(await scripted.applied == [WovenVMResources(memoryBytes: 6 << 30, diskBytes: 80 << 30)])
        let messages = seen.compactMap(\.message)
        #expect(messages.contains("Downloading Linux for the bots VM (first start only)… 42%"))
        #expect(messages.contains("Preparing the bots VM: Preparing the VM disk…"))
        #expect(messages.contains("Setting up the bots VM: Installing Docker Engine…"))
        #expect(seen.allSatisfy { $0.socketPath == "/private/tmp/wovenmatter-vm-test/docker.sock" })
        #expect(seen.last?.state == .running)
    }

    @Test func noCapMeansNoVMCapAndTinyCapsMeetTheVMsMinimums() {
        #expect(WovenVMBotEngineHost.vmResources(.init(poolBytes: nil, perBotBytes: 4 * gib, diskBytes: nil))
                == WovenVMResources(memoryBytes: nil, diskBytes: nil))
        #expect(WovenVMBotEngineHost.vmResources(.init(poolBytes: gib / 2, perBotBytes: nil, diskBytes: 2 * gib))
                == WovenVMResources(memoryBytes: WovenVMResources.minimumMemoryBytes, diskBytes: WovenVMResources.minimumDiskBytes))
    }

    @Test func aFailedFirstBootThrowsWithTheHelpersReason() async throws {
        let scripted = ScriptedVM([vm(.booting), vm(.booting), vm(.failed, failure: "The guest did not answer within 10 minutes.")])
        let engine = WovenVMBotEngineHost(vm: scripted, pollInterval: .milliseconds(1))
        var last: BotEngineStatus?
        engine.onStatusChange = { last = $0 }
        await #expect(throws: BotsError.unavailable("The bots VM failed: The guest did not answer within 10 minutes.")) {
            _ = try await engine.ensureRunning(resources: .defaults)
        }
        #expect(last?.state == .failed && last?.message?.contains("did not answer") == true)
        #expect(await engine.status().state == .failed)
    }

    @Test func aHelperThatNeverLeavesStoppedIsReported() async throws {
        let scripted = ScriptedVM([vm(.stopped)])
        let engine = WovenVMBotEngineHost(vm: scripted, pollInterval: .milliseconds(1), stoppedGrace: .milliseconds(20))
        await #expect(throws: BotsError.unavailable("The bots VM did not start.")) { _ = try await engine.ensureRunning(resources: .defaults) }
    }

    @Test func statusAndDiskUseComeFromTheHelper() async throws {
        let scripted = ScriptedVM([vm(.ready, used: 7 << 30, restartPending: true)])
        let engine = WovenVMBotEngineHost(vm: scripted)
        let status = await engine.status()
        #expect(status.state == .running && status.message?.contains("RAM pool applies fully") == true)
        #expect(await engine.diskUsedByBots() == 7 * gib)
        // Without its control socket the helper is simply not running.
        await scripted.setScript([.failure(.unavailable("The Woven VM helper is not running."))])
        #expect(await engine.status().state == .stopped)
        #expect(await engine.diskUsedByBots() == nil)
        await engine.stop()
        #expect(await scripted.stops == 1)
    }

    @Test func updateWaitsForTheHelperAndReportsARollback() async throws {
        let scripted = ScriptedVM([vm(.ready)])
        await scripted.setAfterUpdate([vm(.ready), vm(.updating, detail: "Saving a snapshot"), vm(.updating, detail: "Upgrading the guest"),
                                       vm(.booting), vm(.ready)])
        let engine = WovenVMBotEngineHost(vm: scripted, pollInterval: .milliseconds(1))
        var seen: [String] = []
        engine.onStatusChange = { if let message = $0.message { seen.append(message) } }
        try await engine.update()
        #expect(await scripted.updates == 1)
        #expect(seen.contains("Updating the bots VM: Upgrading the guest…"))

        await scripted.setScript([vm(.ready)])
        await scripted.setAfterUpdate([vm(.updating), vm(.ready, updateFailure: "Docker did not start.")])
        await #expect(throws: BotsError.unavailable("The bots VM update failed and was rolled back: Docker did not start.")) {
            try await engine.update()
        }
        // An update needs a running VM.
        await scripted.setScript([vm(.booting)])
        await #expect(throws: BotsError.self) { try await engine.update() }
    }

    @Test func theFactoryNamesWhyAMacCannotRunTheVM() {
        #expect(BotEngineHostFactory.unavailableReason(isAppleSilicon: false).contains("Apple silicon"))
        #expect(BotEngineHostFactory.unavailableReason(isAppleSilicon: true).contains("bots VM helper"))
        #expect(!BotEngineHostFactory.unavailableReason(isAppleSilicon: true).contains("yet"))
    }
}
