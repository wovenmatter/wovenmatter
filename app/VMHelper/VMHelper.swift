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
    /// The guest kernel last seen leaves the pages it hands to the balloon
    /// untouched, so the next boot can be capped from the start.
    var guestLeavesBalloonUntouched: Bool?
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
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(paths.root.path, 0o700)
        // The socket directory may be under /private/tmp: never listen in one
        // another user created or can enter.
        try WovenVMPaths.preparePrivateDirectory(paths.socketDirectory)
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
                try bootAndWait(timeout: Self.readyLimit, report: true)
            } catch {
                fail(error)
            }
        }
    }

    /// Each provisioning step has its own limit (`WovenVMProvisionWatch`);
    /// this only ends a wait that would otherwise never end.
    static let readyLimit: TimeInterval = 4 * 3600

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
            balloon = WovenVMBalloonPolicy.State()
            balloonAllowed = state.guestLeavesBalloonUntouched == true
            agentAnswered = false
            guestCommandLine = nil
            idleSince = nil
            vmProcess = nil
            guestDemand = nil
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
        // Cap the guest before it touches memory it will not need: untouched
        // pages cost the Mac nothing, touched ones stay until the VM restarts.
        let capped = queue.sync { () -> UInt64? in
            guard balloonAllowed else { return nil }
            let target = WovenVMBalloonPolicy.bootTarget(ceiling: ceiling())
            balloon.target = target
            applyBalloon(target: target)
            return target
        }
        log("VM started with \(configuration.memorySize >> 20) MiB and \(configuration.cpuCount) CPUs"
            + (capped.map { ", capped at \($0 >> 20) MiB" } ?? ""))
    }

    /// Waits until the guest is provisioned and Docker Engine answers.
    private func bootAndWait(timeout: TimeInterval, report: Bool) throws {
        if report { set(.booting, "Starting the VM") }
        try boot()
        try waitUntilReadyRetrying(timeout: timeout, report: report)
        // Provisioning sets the guest kernel's memory options; they apply from
        // its next boot. Once, so a guest that keeps refusing them still runs.
        if queue.sync(execute: { guestCommandLine.map { !WovenVMBalloonPolicy.guestLeavesBalloonUntouched(commandLine: $0) } ?? false }) {
            log("restarting the guest once to apply its memory settings")
            if report { set(.booting, "Restarting the VM to apply its memory settings") }
            stopGuest()
            try boot()
            try waitUntilReadyRetrying(timeout: timeout, report: report)
        }
        if report { set(.ready, nil) }
        afterReady()
    }

    /// A failed or stuck guest gets one fresh boot: provisioning resumes on
    /// every boot until it succeeds, and a reboot clears what a guest kernel
    /// fault leaves wedged (measured on a MacBook Air: a slab fault while
    /// loading `overlay` hung every later module load, so containerd never
    /// started).
    private func waitUntilReadyRetrying(timeout: TimeInterval, report: Bool) throws {
        do {
            try waitUntilReady(timeout: timeout, report: report)
        } catch let failure as GuestNotReady {
            log("\(failure.message) Restarting the VM to try once more.")
            if report { set(.booting, "Restarting the VM to retry setup") }
            stopGuest()
            try boot()
            try waitUntilReady(timeout: timeout, report: report)
        }
    }

    /// Follows provisioning (`WovenVMProvisionWatch`): every step has a time
    /// limit, so a stuck guest fails naming the step. A failure records the
    /// guest's diagnostics in `helper.log`.
    private func waitUntilReady(timeout: TimeInterval, report: Bool) throws {
        let started = Date()
        var watch = WovenVMProvisionWatch(now: started)
        while Date().timeIntervalSince(started) < timeout {
            guard queue.sync(execute: { machine != nil }) else {
                throw WovenVMError.failed("The VM stopped while starting.\(consoleTail())")
            }
            let status = try? agent(["op": "status"], timeout: 10)
            if let status { recordGuest(status) }
            switch watch.observe(status.map(WovenVMProvisionWatch.Report.init(provisioningIn:)), now: Date()) {
            case .done:
                return
            case .failed(let message):
                throw GuestNotReady(message: message + (status == nil ? consoleTail() : "") + recordDiagnostics())
            case .waiting(let step):
                if report, status != nil { set(.provisioning, step) }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw WovenVMError.failed("The VM did not become ready in time.")
    }

    private func consoleTail() -> String {
        let lines = Self.tail(of: paths.console, lines: 5)
        return lines.isEmpty ? "" : " Console: " + lines.split(separator: "\n").joined(separator: " | ")
    }

    static func tail(of file: URL, lines: Int, bytes: Int = 16_384) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Writes what explains a failure to `helper.log` and returns a sentence
    /// naming a guest kernel fault, if the guest reported one.
    private func recordDiagnostics() -> String {
        guard let guest = try? agent(["op": "diagnostics"], timeout: 60) else {
            log("guest diagnostics unavailable: the guest agent did not answer")
            return ""
        }
        let texts = WovenVMGuestDiagnostics.texts(guest)
        for key in ["kernel_alerts", "failed_units", "jobs", "provision_log"] {
            guard let text = texts[key], !text.isEmpty else { continue }
            let lines = text.split(separator: "\n").suffix(key == "provision_log" ? 15 : 30)
            log("guest \(key):\n  " + lines.joined(separator: "\n  "))
        }
        return WovenVMGuestDiagnostics.kernelFault(texts).map { " The guest kernel reported a fault: \($0)" } ?? ""
    }

    /// Helper, console and guest state for `GET /v1/diagnostics`.
    func diagnostics() -> WovenVMDiagnostics {
        var guest: [String: String]?
        var guestError: String?
        do {
            guest = WovenVMGuestDiagnostics.texts(try agent(["op": "diagnostics"], timeout: 60))
        } catch {
            guestError = (error as? WovenVMError)?.errorDescription ?? error.localizedDescription
        }
        return WovenVMDiagnostics(status: status(), helperLog: Self.tail(of: paths.log, lines: 80),
                                  console: Self.tail(of: paths.console, lines: 40), guest: guest,
                                  guestError: guestError)
    }

    private func recordGuest(_ status: [String: Any]) {
        let provisioned = (status["provisioned"] as? [String: Any])?["guestVersion"] as? Int
        let info = WovenVMGuestInfo(os: status["os"] as? String, kernel: status["kernel"] as? String,
                                    docker: status["docker"] as? String, provisionedVersion: provisioned)
        let commandLine = status["cmdline"] as? String
        queue.async { [self] in
            guest = info
            // An older guest agent does not say; its balloon stays open.
            guard let commandLine, commandLine != guestCommandLine else { return }
            guestCommandLine = commandLine
            let untouched = WovenVMBalloonPolicy.guestLeavesBalloonUntouched(commandLine: commandLine)
            balloonAllowed = untouched
            if state.guestLeavesBalloonUntouched != untouched {
                state.guestLeavesBalloonUntouched = untouched
                saveState()
            }
            if !untouched { applyBalloon(target: nil) }
        }
    }

    private func afterReady() {
        pushTime()
        pushHostAddresses()
        applyDiskCap()
        refreshUsage()
        // A guest that zeroes ballooned pages would make the Mac back them all.
        queue.sync { if !balloonAllowed { applyBalloon(target: nil) } }
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
            do { try bootAndWait(timeout: Self.readyLimit, report: true) } catch { fail(error) }
        }
    }

    /// Graceful guest shutdown, then the power button, then a hard stop.
    private func stopGuest() {
        let waiter = DispatchSemaphore(value: 0)
        let running = queue.sync { () -> Bool in
            guard machine != nil else { return false }
            // A guest shutting down stops answering; that is not pressure.
            agentAnswered = false
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
        _ = try? agent(["op": "set_host_addresses", "addresses": HostMetrics.addresses()], timeout: 100)
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

    /// Runs on `queue`.
    private func ceiling() -> UInt64 {
        WovenVMBalloonPolicy.ceiling(bootedBytes: bootedMemory, requestedBytes: desiredMemory())
    }

    /// Runs on `queue`. `target` nil restores the ceiling.
    private func applyBalloon(target: UInt64?) {
        guard let vm = machine, let device = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        let ceiling = ceiling()
        let value = (min(target ?? ceiling, ceiling)) / (1 << 20) * (1 << 20)
        if target == nil { balloon.target = nil }
        if balloonTarget != value {
            device.targetVirtualMachineMemorySize = value
            balloonTarget = value
        }
    }

    /// Every second, while the VM runs: keep the guest capped at what it uses
    /// plus headroom (see `WovenVMBalloonPolicy`). It fails open: a guest too
    /// starved to answer gets its whole pool back at once, because Linux's own
    /// deflate-on-OOM frees only 1 MiB per OOM round and a fast allocation
    /// would otherwise stall until the balloon opens.
    private func balloonTick() {
        let proceed = queue.sync { () -> Bool in
            guard balloonAllowed, !ballooning, machine != nil else { return false }
            ballooning = true
            return true
        }
        guard proceed else { return }
        defer { queue.sync { ballooning = false } }
        guard let reply = try? agent(["op": "meminfo"], timeout: 1),
              let memory = WovenVMGuestMemory(agentReply: reply) else {
            // Before the agent first answers, the guest is still booting.
            let opened = queue.sync { () -> Bool in
                guard agentAnswered, stopWaiters.isEmpty, machine != nil, balloonTarget != ceiling() else { return false }
                _ = WovenVMBalloonPolicy.unanswered(&balloon, ceiling: ceiling(), now: Date())
                applyBalloon(target: nil)
                return true
            }
            if opened { log("balloon opened: the guest agent did not answer in time") }
            return
        }
        let change = queue.sync { () -> (from: UInt64, to: UInt64, pressure: Bool)? in
            guard machine != nil, balloonAllowed else { return nil }
            agentAnswered = true
            let current = balloonTarget ?? ceiling()
            let decision = WovenVMBalloonPolicy.step(&balloon, memory: memory, ceiling: ceiling(),
                                                     booted: bootedMemory, now: Date())
            guestDemand = decision.demand
            guard decision.target != current else { return nil }
            applyBalloon(target: decision.target)
            return (current, decision.target, decision.underPressure)
        }
        if let change, max(change.from, change.to) - min(change.from, change.to) >= 512 << 20 {
            log("balloon target \(change.from >> 20) -> \(change.to >> 20) MiB" + (change.pressure ? " (memory pressure)" : ""))
        }
    }

    private var ballooning = false
    private var balloon = WovenVMBalloonPolicy.State()
    /// This boot's guest kernel leaves ballooned pages untouched.
    private var balloonAllowed = false
    private var agentAnswered = false
    private var guestCommandLine: String?
    private var guestDemand: UInt64?
    private var idleSince: Date?
    private var lastIdleRestart: Date?

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
        // Idle: no container runs and nothing else is busy (an image build runs
        // no listed container). An older agent does not report the load.
        let activity = try? agent(["op": "running_containers"], timeout: 10)
        let idle = activity?["running"] as? Int == 0 && ((activity?["load"] as? NSNumber)?.doubleValue ?? 0) < 0.5
        let reason = queue.sync { () -> String? in
            let now = Date()
            idleSince = idle ? (idleSince ?? now) : nil
            guard idle else { return nil }
            if bootedMemory != desiredMemory() { return "to apply the new RAM pool" }
            // Virtualization never takes back memory the guest once touched;
            // only a restart does. Bots are stopped, so nothing is lost.
            guard let footprint = vmProcess.flatMap(HostMetrics.footprint),
                  WovenVMBalloonPolicy.shouldRestartIdle(footprint: footprint, target: balloonTarget ?? ceiling(),
                                                         idleSince: idleSince, lastRestart: lastIdleRestart, now: now)
            else { return nil }
            lastIdleRestart = now
            return "to give \((footprint - min(footprint, balloonTarget ?? ceiling())) >> 20) MiB back to the Mac"
        }
        if let reason {
            log("restarting the idle VM \(reason)")
            restartVM()
        }
    }

    // MARK: Sequences

    func restartVM() {
        guard beginSequence() else { return }
        defer { endSequence() }
        set(.booting, "Restarting the VM")
        stopGuest()
        do { try bootAndWait(timeout: Self.readyLimit, report: true) } catch { fail(error) }
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
            do { try bootAndWait(timeout: Self.readyLimit, report: true) } catch { fail(error) }
            return
        }
        do {
            set(.updating, "Starting the VM")
            try boot()
            try waitUntilReady(timeout: 1800, report: false)
            set(.updating, "Updating guest packages and Docker Engine")
            let files = try WovenVMGuestFiles.files(resources: resources, version: version)
            _ = try agent(["op": "update", "files": files.mapValues { $0.base64EncodedString() }], timeout: 120)
            try waitForUpdate(timeout: Self.readyLimit)
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
                try bootAndWait(timeout: Self.readyLimit, report: true)
            } catch {
                fail(error)
            }
        }
    }

    private func waitForUpdate(timeout: TimeInterval) throws {
        let started = Date()
        var watch = WovenVMProvisionWatch(now: started)
        while Date().timeIntervalSince(started) < timeout {
            Thread.sleep(forTimeInterval: 2)
            let status = try? agent(["op": "status"], timeout: 10)
            switch watch.observe(status.map(WovenVMProvisionWatch.Report.init(updateIn:)), now: Date()) {
            case .done: return
            case .failed(let message): throw WovenVMError.failed(message + recordDiagnostics())
            case .waiting(let step): if status != nil { set(.updating, step) }
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
            case ("GET", "/v1/diagnostics"):
                return json(200, diagnostics())
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

/// Provisioning failed or stopped making progress; worth one fresh boot.
struct GuestNotReady: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
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
