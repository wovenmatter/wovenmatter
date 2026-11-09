import Darwin
import Foundation
import Virtualization

/// Persisted helper state, separate from the user's resource settings.
struct HelperState: Codable {
    var machineIdentifier: Data?
    var macAddress: String?
    var instanceID = "woven-" + UUID().uuidString.lowercased()
    var forwards: [WovenVMForward] = []
    var updateFailure: String?
}

/// Owns the Woven VM. All mutable state is confined to `queue`, which is also
/// the Virtualization.framework queue. Blocking sequences (boot, update,
/// restart, stop) run on worker threads and only touch state through `queue`.
final class VMHelper: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let paths: WovenVMPaths
    let resources: URL
    let version: WovenVMGuestVersion
    let queue = DispatchQueue(label: "wovenmatter.vm")
    private let acceptQueue = DispatchQueue(label: "wovenmatter.vm.accept", attributes: .concurrent)

    private var machine: VZVirtualMachine?
    private var phase: WovenVMPhase = .stopped
    private var detail: String?
    private var failure: String?
    private var progress: Double?
    private var config: WovenVMResources
    private var state: HelperState
    private var bootedMemory: UInt64 = 0
    private var balloonTarget: UInt64?
    private var guest: WovenVMGuestInfo?
    private var guestDisk: (used: UInt64, cap: UInt64)?
    private var vmProcess: pid_t?
    private var listeners: [Listener] = []
    private var forwardListeners: [String: Listener] = [:]
    /// A sequence (boot, update, restart, stop) owns the VM; unexpected stops
    /// are not auto-restarted while one runs.
    private var busy = false
    private var maintaining = false
    private var exiting = false
    private var stopWaiters: [DispatchSemaphore] = []
    private var unexpectedStops: [Date] = []
    private var ticks = 0
    private var lockDescriptor: Int32 = -1

    init(paths: WovenVMPaths, resources: URL) throws {
        self.paths = paths
        self.resources = resources
        version = try WovenVMGuestFiles.loadVersion(resources: resources)
        config = (try? JSONDecoder().decode(WovenVMResources.self, from: Data(contentsOf: paths.config))) ?? WovenVMResources()
        state = (try? JSONDecoder().decode(HelperState.self, from: Data(contentsOf: paths.state))) ?? HelperState()
    }

    // MARK: Startup

    func start() throws {
        for directory in [paths.root, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            chmod(directory.path, 0o700)
        }
        lockDescriptor = open(paths.root.appending(path: "helper.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw HelperAlreadyRunning()
        }
        let control = try Sockets.listenUnix(at: paths.controlSocket)
        let engine = try Sockets.listenUnix(at: paths.engineSocket)
        queue.sync {
            listeners = [
                Listener(fd: control, queue: acceptQueue) { [self] fd in detach { self.serveControl(fd) } },
                Listener(fd: engine, queue: acceptQueue) { [self] fd in detach { self.serveEngine(fd) } }
            ]
            restoreForwards()
        }
        log("helper started for \(paths.root.path)")
        let timer = DispatchSource.makeTimerSource(queue: acceptQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [self] in detach { self.maintain() } }
        timer.resume()
        maintenanceTimer = timer
        let balloonTimer = DispatchSource.makeTimerSource(queue: acceptQueue)
        balloonTimer.schedule(deadline: .now() + 1, repeating: 1)
        balloonTimer.setEventHandler { [self] in detach { self.balloonTick() } }
        balloonTimer.resume()
        self.balloonTimer = balloonTimer
        detach { [self] in
            guard beginSequence() else { return }
            defer { endSequence() }
            do {
                try prepare()
                try bootAndWait(timeout: 3600, report: true)
            } catch {
                fail(error)
            }
        }
    }

    private var maintenanceTimer: (any DispatchSourceTimer)?
    private var balloonTimer: (any DispatchSourceTimer)?

    private func prepare() throws {
        if !FileManager.default.fileExists(atPath: paths.disk.path) {
            set(.downloading, "Downloading \(version.image.name)", progress: 0)
            let image = try GuestSetup.download(version.image, into: paths.downloads) { [self] value in
                queue.async { self.progress = value }
            }
            set(.preparing, "Preparing the VM disk", progress: 0)
            try GuestSetup.createRootDisk(from: image, at: paths.disk) { [self] value in
                queue.async { self.progress = value }
            }
            try? FileManager.default.removeItem(at: paths.downloads)
        }
        set(.preparing, "Preparing the bot disk")
        try GuestSetup.ensureDataDisk(at: GuestSetup.dataDiskURL(paths), bytes: dataDiskBytes())
        if !FileManager.default.fileExists(atPath: paths.seed.path) {
            let files = try WovenVMGuestFiles.files(resources: resources, version: version)
            let instance = queue.sync { state.instanceID }
            try GuestSetup.createSeed(at: paths.seed,
                                      userData: WovenVMGuestFiles.userData(files: files, diskCapBytes: diskCap()),
                                      metaData: WovenVMGuestFiles.metaData(instanceID: instance),
                                      scratch: paths.root)
        }
    }

    /// The sparse data disk spans the whole volume so raising the cap never
    /// needs a resize; the cap itself is enforced in the guest.
    private func dataDiskBytes() -> UInt64 {
        let total = HostMetrics.volume(containing: paths.root).total
        return max(total, 64 << 30) / (1 << 20) * (1 << 20)
    }

    private func diskCap() -> UInt64 { queue.sync { config.diskBytes } ?? dataDiskBytes() }

    private func desiredMemory() -> UInt64 {
        WovenVMSizing.memoryBytes(requested: config.memoryBytes, physical: HostMetrics.physicalMemory,
                                  maximumAllowed: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    // MARK: Virtual machine

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                                     min(ProcessInfo.processInfo.activeProcessorCount,
                                         VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        configuration.memorySize = queue.sync { desiredMemory() }

        let platform = VZGenericPlatformConfiguration()
        let identifier = queue.sync { state.machineIdentifier.flatMap(VZGenericMachineIdentifier.init(dataRepresentation:)) }
            ?? VZGenericMachineIdentifier()
        platform.machineIdentifier = identifier
        configuration.platform = platform

        let loader = VZEFIBootLoader()
        loader.variableStore = FileManager.default.fileExists(atPath: paths.efiVariables.path)
            ? VZEFIVariableStore(url: paths.efiVariables)
            : try VZEFIVariableStore(creatingVariableStoreAt: paths.efiVariables)
        configuration.bootLoader = loader

        func disk(_ url: URL, _ name: String, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: readOnly,
                                                                    cachingMode: .automatic, synchronizationMode: .full)
            let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            device.blockDeviceIdentifier = name
            return device
        }
        configuration.storageDevices = [try disk(paths.disk, "woven-root", readOnly: false),
                                        try disk(GuestSetup.dataDiskURL(paths), "woven-data", readOnly: false),
                                        try disk(paths.seed, "woven-seed", readOnly: true)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        let mac = queue.sync { state.macAddress.flatMap(VZMACAddress.init(string:)) } ?? .randomLocallyAdministered()
        network.macAddress = mac
        configuration.networkDevices = [network]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        let consoleFD = open(paths.console.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if consoleFD >= 0 {
            console.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil, fileHandleForWriting: FileHandle(fileDescriptor: consoleFD, closeOnDealloc: true))
            configuration.serialPorts = [console]
        }
        try configuration.validate()
        queue.sync {
            state.machineIdentifier = identifier.dataRepresentation
            state.macAddress = mac.string
            saveState()
        }
        return configuration
    }

    /// After a crash or SIGKILL, launchd restarts the helper before the old
    /// Virtualization process has let go of the disks and EFI store; starting
    /// then fails ("the boot loader is invalid"). Wait for it, then retry.
    private func boot() throws {
        var deadline = Date() + 30
        while HostMetrics.virtualMachineProcess(holding: paths.disk) != nil
                && queue.sync(execute: { machine == nil }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        deadline = Date() + 30
        while true {
            do { return try startMachine() } catch {
                guard Date() < deadline else { throw error }
                log("\(error.localizedDescription) Retrying.")
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    private func startMachine() throws {
        let configuration = try makeConfiguration()
        let started = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        queue.sync {
            let vm = VZVirtualMachine(configuration: configuration, queue: queue)
            vm.delegate = self
            machine = vm
            bootedMemory = configuration.memorySize
            balloonTarget = nil
            vmProcess = nil
            guestDemand = nil
            balloonLowerSince = nil
            guestDisk = nil
            vm.start { result in
                if case .failure(let error) = result { outcome.error = error }
                started.signal()
            }
        }
        started.wait()
        if let error = outcome.error {
            queue.sync { machine = nil }
            throw WovenVMError.failed("The VM did not start: \(error.localizedDescription)")
        }
        log("VM started with \(configuration.memorySize >> 20) MiB and \(configuration.cpuCount) CPUs")
    }

    /// Waits until the guest is provisioned and Docker Engine answers.
    private func bootAndWait(timeout: TimeInterval, report: Bool) throws {
        if report { set(.booting, "Starting the VM") }
        try boot()
        try waitUntilReady(timeout: timeout, report: report)
        if report { set(.ready, nil) }
        afterReady()
    }

    private func waitUntilReady(timeout: TimeInterval, report: Bool) throws {
        let started = Date()
        var reached = false
        while Date().timeIntervalSince(started) < timeout {
            guard queue.sync(execute: { machine != nil }) else {
                throw WovenVMError.failed("The VM stopped while starting.\(consoleTail())")
            }
            if let status = try? agent(["op": "status"], timeout: 5) {
                reached = true
                recordGuest(status)
                let provision = status["provision"] as? [String: Any]
                if status["provisioned"] is [String: Any], status["docker"] is String { return }
                if provision?["phase"] as? String == "failed" {
                    throw WovenVMError.failed(provision?["error"] as? String ?? "Provisioning failed.")
                }
                if report { set(.provisioning, provision?["step"] as? String ?? "Starting the guest") }
            } else if !reached && Date().timeIntervalSince(started) > 600 {
                throw WovenVMError.failed("The guest did not start.\(consoleTail())")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw WovenVMError.failed("The VM did not become ready in time.")
    }

    private func consoleTail() -> String {
        guard let data = try? Data(contentsOf: paths.console), !data.isEmpty else { return "" }
        let lines = String(decoding: data.suffix(2048), as: UTF8.self).split(separator: "\n").suffix(5)
        return " Console: " + lines.joined(separator: " | ")
    }

    private func recordGuest(_ status: [String: Any]) {
        let provisioned = (status["provisioned"] as? [String: Any])?["guestVersion"] as? Int
        let info = WovenVMGuestInfo(os: status["os"] as? String, kernel: status["kernel"] as? String,
                                    docker: status["docker"] as? String, provisionedVersion: provisioned)
        queue.async { self.guest = info }
    }

    private func afterReady() {
        pushTime()
        pushHostAddresses()
        applyDiskCap()
        refreshUsage()
        queue.sync { applyBalloon(target: nil) }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { handleStop(virtualMachine, error: nil) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        handleStop(virtualMachine, error: error)
    }

    /// Runs on `queue`. A guest reboot also arrives here, so an unexpected stop
    /// boots again; repeated crashes leave the VM failed with the reason.
    private func handleStop(_ virtualMachine: VZVirtualMachine, error: (any Error)?) {
        guard virtualMachine === machine else { return }
        machine = nil
        vmProcess = nil
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.signal() }
        log("VM stopped" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        guard !busy, !exiting else { return }
        unexpectedStops = unexpectedStops.filter { Date().timeIntervalSince($0) < 600 } + [Date()]
        if unexpectedStops.count > 3 {
            phase = .failed
            failure = "The VM stopped repeatedly" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            return
        }
        phase = .booting
        detail = "Restarting the VM"
        detach { [self] in
            guard beginSequence() else { return }
            defer { endSequence() }
            do { try bootAndWait(timeout: 1800, report: true) } catch { fail(error) }
        }
    }

    /// Graceful guest shutdown, then the power button, then a hard stop.
    private func stopGuest() {
        let waiter = DispatchSemaphore(value: 0)
        let running = queue.sync { () -> Bool in
            guard machine != nil else { return false }
            stopWaiters.append(waiter)
            return true
        }
        guard running else { return }
        if (try? agent(["op": "poweroff"], timeout: 5)) != nil, waiter.wait(timeout: .now() + 30) == .success { return }
        queue.async {
            if let vm = self.machine, vm.canRequestStop { try? vm.requestStop() }
        }
        if waiter.wait(timeout: .now() + 10) == .success { return }
        queue.async {
            guard let vm = self.machine else { return }
            vm.stop { _ in self.handleStop(vm, error: nil) }
        }
        _ = waiter.wait(timeout: .now() + 15)
    }

    private func beginSequence() -> Bool {
        queue.sync {
            guard !busy, !exiting else { return false }
            busy = true
            return true
        }
    }

    private func endSequence() { queue.sync { busy = false } }

    // MARK: Guest agent and vsock

    /// A connected vsock stream to a guest port. The descriptor is a dup the
    /// caller owns, so the framework's connection object can go away.
    func connect(port: UInt32, timeout: TimeInterval) throws -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let outcome = ConnectOutcome()
        queue.async {
            guard let vm = self.machine, vm.state == .running,
                  let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
                outcome.finish(fd: -1, error: WovenVMError.unavailable("The VM is not running."))
                done.signal()
                return
            }
            device.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    let fd = dup(connection.fileDescriptor)
                    connection.close()
                    outcome.finish(fd: fd, error: nil)
                case .failure(let error):
                    outcome.finish(fd: -1, error: error)
                }
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            outcome.abandon()
            throw WovenVMError.unavailable("The VM did not accept a connection in time.")
        }
        return try outcome.take()
    }

    func agent(_ request: [String: Any], timeout: TimeInterval = 15) throws -> [String: Any] {
        let fd = try connect(port: WovenVMGuestPort.agent, timeout: min(5, timeout))
        defer { close(fd) }
        Sockets.setBlocking(fd)
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(UInt8(ascii: "\n"))
        guard Sockets.writeAll(fd, payload) else { throw WovenVMError.unavailable("The guest agent closed the connection.") }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while reply.last != UInt8(ascii: "\n") {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            reply.append(buffer, count: count)
            guard reply.count < 8 << 20 else { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw WovenVMError.unavailable("The guest agent did not answer.")
        }
        guard object["ok"] as? Bool == true else {
            throw WovenVMError.failed(object["error"] as? String ?? "The guest agent reported an error.")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    // MARK: Time, host addresses, usage, balloon

    func pushTime() {
        let now = clock_gettime_nsec_np(CLOCK_REALTIME)
        if let result = try? agent(["op": "set_time", "epoch_ns": now], timeout: 5),
           result["set"] as? Bool == true {
            log("corrected guest clock by \(((result["delta_ns"] as? Int) ?? 0) / 1_000_000) ms")
        }
    }

    func pushTimeAfterWake() {
        // The guest's clock stood still while the Mac slept. The agent may need
        // a moment after wake, so retry briefly.
        for delay in [0.0, 2, 5, 10] {
            Thread.sleep(forTimeInterval: delay)
            pushTime()
        }
    }

    private func pushHostAddresses() {
        _ = try? agent(["op": "set_host_addresses", "addresses": HostMetrics.addresses()], timeout: 30)
    }

    private func applyDiskCap() {
        let cap = diskCap()
        do {
            let result = try agent(["op": "set_disk_cap", "bytes": cap], timeout: 600)
            recordDisk(result)
        } catch {
            log("disk cap not applied: \(error.localizedDescription)")
        }
    }

    private func recordDisk(_ result: [String: Any]) {
        guard let used = (result["used"] as? NSNumber)?.uint64Value,
              let cap = (result["cap"] as? NSNumber)?.uint64Value else { return }
        queue.async { self.guestDisk = (used, cap) }
    }

    private func refreshUsage() {
        if let disk = try? agent(["op": "disk"], timeout: 5) { recordDisk(disk) }
        let needsProcess = queue.sync { vmProcess == nil && machine != nil }
        if needsProcess, let pid = HostMetrics.virtualMachineProcess(holding: paths.disk) {
            queue.sync { vmProcess = pid }
        }
    }

    /// Runs on `queue`. `target` nil restores the ceiling.
    private func applyBalloon(target: UInt64?) {
        guard let vm = machine, let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        let ceiling = WovenVMBalloonPolicy.ceiling(bootedBytes: bootedMemory, requestedBytes: desiredMemory())
        let value = (min(target ?? ceiling, ceiling)) / (1 << 20) * (1 << 20)
        if balloonTarget != value {
            balloon.targetVirtualMachineMemorySize = value
            balloonTarget = value
        }
    }

    /// Every second: keep the balloon over what the guest does not need, so the
    /// Mac keeps that memory (see `WovenVMBalloonPolicy`). It fails open: a
    /// guest too starved to answer gets its whole pool back at once, because
    /// Linux's own deflate-on-OOM frees only 1 MiB per OOM round and a fast
    /// allocation would otherwise stall until the balloon opens.
    private func balloonTick() {
        let proceed = queue.sync { () -> Bool in
            guard phase == .ready, !busy, !ballooning, machine != nil else { return false }
            ballooning = true
            return true
        }
        guard proceed else { return }
        defer { queue.sync { ballooning = false } }
        guard let memory = try? agent(["op": "meminfo"], timeout: 1),
              let total = (memory["total"] as? NSNumber)?.uint64Value,
              let available = (memory["available"] as? NSNumber)?.uint64Value else {
            let opened = queue.sync { () -> Bool in
                guard phase == .ready, machine != nil, balloonTarget != nil else { return false }
                let before = balloonTarget
                balloonLowerSince = nil
                applyBalloon(target: nil)
                return before != balloonTarget
            }
            if opened { log("balloon opened: the guest agent did not answer in time") }
            return
        }
        let change = queue.sync { () -> (from: UInt64, to: UInt64)? in
            let ceiling = WovenVMBalloonPolicy.ceiling(bootedBytes: bootedMemory, requestedBytes: desiredMemory())
            let current = balloonTarget ?? ceiling
            let desired = WovenVMBalloonPolicy.desiredTarget(ceiling: ceiling, booted: bootedMemory, current: current,
                                                             guestTotal: total, guestAvailable: available)
            let ballooned = bootedMemory > current ? bootedMemory - current : 0
            let used = total > available ? total - available : 0
            guestDemand = used > ballooned ? used - ballooned : 0
            let (target, since) = WovenVMBalloonPolicy.next(current: current, desired: desired,
                                                            lowerSince: balloonLowerSince, now: Date())
            balloonLowerSince = since
            guard target != current else { return nil }
            applyBalloon(target: target)
            return (current, target)
        }
        if let change, max(change.from, change.to) - min(change.from, change.to) >= 512 << 20 {
            log("balloon target \(change.from >> 20) -> \(change.to >> 20) MiB")
        }
    }

    private var ballooning = false
    private var balloonLowerSince: Date?
    private var guestDemand: UInt64?

    private func maintain() {
        let proceed = queue.sync { () -> Bool in
            guard phase == .ready, !busy, !maintaining, machine != nil else { return false }
            maintaining = true
            ticks += 1
            return true
        }
        guard proceed else { return }
        defer { queue.sync { maintaining = false } }
        let tick = queue.sync { ticks }
        refreshUsage()
        if tick % 4 == 0 {
            pushTime()
            pushHostAddresses()
        }
        // Blocks bots delete stay allocated in the sparse images until trimmed.
        // ext4 skips groups already trimmed since mount, so this is cheap.
        if tick % 40 == 0 { _ = try? agent(["op": "trim"], timeout: 600) }
        let restart = queue.sync { bootedMemory != desiredMemory() }
        if restart, let running = try? agent(["op": "running_containers"], timeout: 10),
           running["running"] as? Int == 0 {
            log("restarting the idle VM to apply the new RAM pool")
            restartVM()
        }
    }

    // MARK: Sequences

    func restartVM() {
        guard beginSequence() else { return }
        defer { endSequence() }
        set(.booting, "Restarting the VM")
        stopGuest()
        do { try bootAndWait(timeout: 1800, report: true) } catch { fail(error) }
    }

    func terminate(code: Int32) {
        queue.sync {
            exiting = true
            busy = true
            phase = .stopped
            detail = "Stopping the VM"
        }
        stopGuest()
        unlink(paths.engineSocket.path)
        unlink(paths.controlSocket.path)
        log("helper exiting (\(code))")
        exit(code)
    }

    private let snapshotFiles = ["disk.img", "data.img", "efi-vars.fd"]

    /// APFS clones of the disks taken with the guest shut down; one is kept.
    private func takeSnapshot() throws {
        let directory = paths.snapshot
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in snapshotFiles {
            guard clonefile(paths.root.appending(path: name).path, directory.appending(path: name).path, 0) == 0 else {
                throw Sockets.posixError("snapshot \(name)")
            }
        }
        let info = ["at": ISO8601DateFormatter().string(from: Date()), "guestVersion": String(queue.sync { guest?.provisionedVersion ?? 0 })]
        try JSONSerialization.data(withJSONObject: info).write(to: directory.appending(path: "info.json"))
    }

    private func restoreSnapshot() throws {
        for name in snapshotFiles {
            let live = paths.root.appending(path: name), saved = paths.snapshot.appending(path: name)
            guard FileManager.default.fileExists(atPath: saved.path) else { throw WovenVMError.failed("The snapshot is incomplete.") }
            unlink(live.path)
            guard clonefile(saved.path, live.path, 0) == 0 else { throw Sockets.posixError("restore \(name)") }
        }
    }

    /// Woven's Update action for the VM: snapshot, update guest packages and the
    /// pinned Docker Engine, reboot, health-check; roll back on any failure.
    func runUpdate() {
        guard beginSequence() else { return }
        defer { endSequence() }
        set(.updating, "Stopping the VM")
        stopGuest()
        do {
            set(.updating, "Saving a snapshot")
            try takeSnapshot()
        } catch {
            log("snapshot failed: \(error.localizedDescription)")
            queue.sync { state.updateFailure = "The snapshot could not be saved: \(error.localizedDescription)"; saveState() }
            do { try bootAndWait(timeout: 1800, report: true) } catch { fail(error) }
            return
        }
        do {
            set(.updating, "Starting the VM")
            try boot()
            try waitUntilReady(timeout: 1800, report: false)
            set(.updating, "Updating guest packages and Docker Engine")
            let files = try WovenVMGuestFiles.files(resources: resources, version: version)
            _ = try agent(["op": "update", "files": files.mapValues { $0.base64EncodedString() }], timeout: 120)
            try waitForUpdate(timeout: 3600)
            set(.updating, "Restarting the VM")
            stopGuest()
            try boot()
            try waitUntilReady(timeout: 1800, report: false)
            let status = try agent(["op": "status"], timeout: 10)
            guard status["docker"] as? String == version.docker.engineVersion else {
                throw WovenVMError.failed("Docker Engine reports \(status["docker"] as? String ?? "nothing") after the update.")
            }
            queue.sync { state.updateFailure = nil; saveState() }
            set(.ready, "Updated")
            afterReady()
            log("update finished")
        } catch {
            log("update failed, rolling back: \(error.localizedDescription)")
            set(.updating, "Update failed; restoring the snapshot")
            stopGuest()
            do {
                try restoreSnapshot()
                queue.sync { state.updateFailure = "The update failed and was rolled back: \(error.localizedDescription)"; saveState() }
                try bootAndWait(timeout: 1800, report: true)
            } catch {
                fail(error)
            }
        }
    }

    private func waitForUpdate(timeout: TimeInterval) throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            Thread.sleep(forTimeInterval: 2)
            guard let status = try? agent(["op": "status"], timeout: 10),
                  let update = status["update"] as? [String: Any] else { continue }
            switch update["phase"] as? String {
            case "ready": return
            case "failed": throw WovenVMError.failed(update["error"] as? String ?? "The guest update failed.")
            default: set(.updating, update["step"] as? String ?? "Updating")
            }
        }
        throw WovenVMError.failed("The guest update did not finish in time.")
    }

    // MARK: Status and settings

    private func set(_ newPhase: WovenVMPhase, _ newDetail: String?, progress newProgress: Double? = nil) {
        let changed = queue.sync { () -> Bool in
            let changed = phase != newPhase || detail != newDetail
            phase = newPhase
            detail = newDetail
            progress = newProgress
            if newPhase != .failed { failure = nil }
            return changed
        }
        if changed { log("\(newPhase.rawValue)" + (newDetail.map { ": \($0)" } ?? "")) }
    }

    private func fail(_ error: any Error) {
        let message = (error as? WovenVMError)?.errorDescription ?? error.localizedDescription
        queue.sync {
            phase = .failed
            failure = message
            progress = nil
        }
        log("failed: \(message)")
    }

    func status() -> WovenVMStatus {
        let volume = HostMetrics.volume(containing: paths.root)
        let allocated = HostMetrics.allocatedBytes(paths.disk) + HostMetrics.allocatedBytes(GuestSetup.dataDiskURL(paths))
        let snapshot = FileManager.default.fileExists(atPath: paths.snapshot.appending(path: "info.json").path)
        return queue.sync {
            let desired = desiredMemory()
            let report = WovenVMResourceReport(
                hostMemoryBytes: HostMetrics.physicalMemory, hostDiskTotalBytes: volume.total, hostDiskFreeBytes: volume.free,
                vmMemoryBytes: machine == nil ? desired : bootedMemory,
                vmMemoryFootprintBytes: vmProcess.flatMap(HostMetrics.footprint),
                guestMemoryUsedBytes: guestDemand,
                balloonTargetBytes: balloonTarget,
                vmDiskCapBytes: guestDisk?.cap ?? config.diskBytes ?? volume.total,
                vmDiskAllocatedBytes: allocated, guestDiskUsedBytes: guestDisk?.used,
                restartPending: machine != nil && bootedMemory != desired)
            var status = WovenVMStatus(phase: phase, detail: detail, failure: failure, progress: progress,
                                       engineSocket: paths.engineSocket.path, resources: report, guest: guest,
                                       forwards: state.forwards, snapshotAvailable: snapshot)
            status.updateFailure = state.updateFailure
            return status
        }
    }

    func applyResources(_ requested: WovenVMResources) throws {
        try WovenVMSizing.validate(requested, physicalMemory: HostMetrics.physicalMemory,
                                   diskTotal: HostMetrics.volume(containing: paths.root).total)
        let ready = queue.sync { () -> Bool in
            config = requested
            if let data = try? JSONEncoder().encode(requested) { try? data.write(to: paths.config, options: .atomic) }
            // A lower pool applies at once through the balloon (soft: the
            // guest may deflate it under pressure); the exact pool applies when
            // the VM next restarts, automatically once idle.
            applyBalloon(target: nil)
            return phase == .ready
        }
        if ready { detach { [self] in applyDiskCap() } }
    }

    // MARK: Forwards

    func addForward(_ request: WovenVMForwardRequest) throws -> WovenVMForward {
        let request = try request.validated()
        if let existing = queue.sync(execute: {
            state.forwards.first {
                $0.container == request.container && $0.address == request.address && $0.port == request.port
                    && (request.hostPort ?? 0 == 0 || $0.hostPort == request.hostPort)
            }
        }) { return existing }
        let (fd, port) = try Sockets.listenLoopback(port: request.hostPort ?? 0)
        let forward = WovenVMForward(id: UUID().uuidString.lowercased(), container: request.container,
                                     address: request.address, port: request.port, hostPort: port)
        queue.sync {
            installForward(forward, fd: fd)
            state.forwards.append(forward)
            saveState()
        }
        log("forwarding 127.0.0.1:\(port) to \(request.container ?? request.address ?? ""):\(request.port)")
        return forward
    }

    func removeForward(id: String) -> Bool {
        queue.sync {
            guard let index = state.forwards.firstIndex(where: { $0.id == id }) else { return false }
            state.forwards.remove(at: index)
            forwardListeners.removeValue(forKey: id)?.cancel()
            saveState()
            return true
        }
    }

    /// Runs on `queue`. The same loopback ports come back after a helper
    /// restart, so Woven's preview proxy keeps pointing at the right place.
    private func restoreForwards() {
        state.forwards = state.forwards.filter { forward in
            guard let (fd, _) = try? Sockets.listenLoopback(port: forward.hostPort) else {
                log("dropped forward on port \(forward.hostPort): the port is taken")
                return false
            }
            installForward(forward, fd: fd)
            return true
        }
        saveState()
    }

    private func installForward(_ forward: WovenVMForward, fd: Int32) {
        forwardListeners[forward.id] = Listener(fd: fd, queue: acceptQueue) { [self] client in
            detach { self.serveForward(client, forward: forward) }
        }
    }

    private func serveForward(_ client: Int32, forward: WovenVMForward) {
        guard let upstream = try? connect(port: WovenVMGuestPort.forward, timeout: 5) else {
            close(client)
            return
        }
        Sockets.setBlocking(upstream)
        var interval = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(upstream, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        let header = forward.container.map { "container \($0) \(forward.port)\n" }
            ?? "address \(forward.address ?? "") \(forward.port)\n"
        guard Sockets.writeAll(upstream, Data(header.utf8)), Sockets.readLine(upstream) == "OK" else {
            close(upstream)
            close(client)
            return
        }
        interval = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(upstream, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        Sockets.splice(client, upstream)
    }

    // MARK: Engine socket and control API

    private func serveEngine(_ client: Int32) {
        guard Sockets.peerIsCurrentUser(client) else { close(client); return }
        let (ready, step) = queue.sync { (phase == .ready, detail ?? phase.rawValue) }
        guard ready, let upstream = try? connect(port: WovenVMGuestPort.docker, timeout: 5) else {
            // Docker clients show {"message"} from an error reply.
            let body = (try? JSONSerialization.data(withJSONObject: ["message": "The Woven VM is not ready (\(step))."])) ?? Data()
            Sockets.setBlocking(client)
            _ = Sockets.writeAll(client, WovenVMControlHTTP.response(status: 503, body: body))
            close(client)
            return
        }
        Sockets.splice(client, upstream)
    }

    private func serveControl(_ fd: Int32) {
        defer { close(fd) }
        guard Sockets.peerIsCurrentUser(fd) else { return }
        Sockets.setBlocking(fd)
        var interval = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var request: WovenVMControlHTTP.Request?
        do {
            while request == nil {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                data.append(buffer, count: count)
                request = try WovenVMControlHTTP.parseRequest(data)
            }
        } catch {
            _ = Sockets.writeAll(fd, reply(400, error))
            return
        }
        _ = Sockets.writeAll(fd, route(request!))
    }

    private func route(_ request: WovenVMControlHTTP.Request) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        func json(_ status: Int, _ value: some Encodable) -> Data {
            WovenVMControlHTTP.response(status: status, body: (try? encoder.encode(value)) ?? Data())
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/status"):
                return json(200, status())
            case ("PUT", "/v1/resources"):
                try applyResources(JSONDecoder().decode(WovenVMResources.self, from: request.body))
                return json(200, status())
            case ("GET", "/v1/forwards"):
                return json(200, queue.sync { state.forwards })
            case ("POST", "/v1/forwards"):
                return json(201, try addForward(JSONDecoder().decode(WovenVMForwardRequest.self, from: request.body)))
            case ("DELETE", let path) where path.hasPrefix("/v1/forwards/"):
                return removeForward(id: String(path.dropFirst("/v1/forwards/".count)))
                    ? WovenVMControlHTTP.response(status: 204, body: Data())
                    : reply(404, WovenVMError.invalid("No such forward."))
            case ("POST", "/v1/update"):
                guard queue.sync(execute: { phase == .ready && !busy }) else {
                    return reply(409, WovenVMError.unavailable("The VM can update only when it is ready."))
                }
                detach { [self] in runUpdate() }
                return json(202, status())
            case ("POST", "/v1/restart"):
                detach { [self] in restartVM() }
                return json(202, status())
            case ("POST", "/v1/stop"):
                detach { [self] in terminate(code: 0) }
                return json(202, status())
            default:
                return reply(404, WovenVMError.invalid("Unknown route \(request.method) \(request.path)."))
            }
        } catch {
            return reply(400, error)
        }
    }

    private func reply(_ status: Int, _ error: any Error) -> Data {
        let message = (error as? WovenVMError)?.errorDescription ?? error.localizedDescription
        return WovenVMControlHTTP.response(status: status,
            body: (try? JSONEncoder().encode(WovenVMControlHTTP.ErrorBody(error: message))) ?? Data())
    }

    // MARK: Persistence and logging

    /// Runs on `queue`.
    private func saveState() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: paths.state, options: .atomic) }
    }

    private let logLock = NSLock()

    func log(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        let path = paths.log.path
        var info = stat()
        if stat(path, &info) == 0 && info.st_size > 2 << 20 { rename(path, path + ".1") }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = Sockets.writeAll(fd, Data(line.utf8))
        close(fd)
    }
}

struct HelperAlreadyRunning: Error, LocalizedError {
    var errorDescription: String? { "Another VM helper already owns this VM." }
}

private final class Outcome: @unchecked Sendable {
    var error: (any Error)?
}

/// A connect that times out may still complete later; its descriptor is then
/// closed instead of leaking.
private final class ConnectOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var error: (any Error)?
    private var abandoned = false

    func finish(fd: Int32, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        if abandoned {
            if fd >= 0 { close(fd) }
            return
        }
        self.fd = fd
        self.error = error
    }

    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        abandoned = true
        if fd >= 0 { close(fd) }
    }

    func take() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard fd >= 0 else { throw WovenVMError.unavailable("The VM refused the connection.") }
        return fd
    }
}

func detach(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.stackSize = 512 << 10
    thread.start()
}
