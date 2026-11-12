// The Woven VM is macOS only (Virtualization framework); Linux library builds skip it.
#if os(macOS)
import CryptoKit
import Foundation

/// The pinned guest selection, `app/VMHelper/guest-version.json`, bundled at
/// `Contents/Resources/WovenVM/guest-version.json`. See docs/DEPENDENCIES.md.
public struct WovenVMGuestVersion: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable {
        public var name: String
        public var serial: String
        public var url: URL
        public var sha256: String
        public var size: UInt64
    }
    public struct Docker: Codable, Sendable, Equatable {
        public var repository: URL
        public var suite: String
        public var keyFingerprint: String
        public var keySha256: String
        public var dockerCE: String
        public var containerd: String
        /// "5:29.9.3-1~ubuntu.26.04~resolute" reports itself as "29.9.3".
        public var engineVersion: String {
            let epochless = dockerCE.split(separator: ":", maxSplits: 1).last.map(String.init) ?? dockerCE
            return String(epochless.prefix { $0 != "-" })
        }
    }
    public var guestVersion: Int
    public var image: Image
    public var docker: Docker
}

/// Builds what the guest receives: the cloud-init NoCloud seed on first boot,
/// and the same files over the agent on every Woven update.
public enum WovenVMGuestFiles {
    /// Bundle file name, guest path and mode. Everything the guest runs is here.
    public static let layout: [(name: String, path: String, mode: String)] = [
        ("agent.py", "/usr/local/lib/woven/agent.py", "0755"),
        ("provision.sh", "/usr/local/lib/woven/provision.sh", "0755"),
        ("egress.sh", "/usr/local/lib/woven/egress.sh", "0755"),
        ("disk-cap.sh", "/usr/local/lib/woven/disk-cap.sh", "0755"),
        ("woven-agent.service", "/etc/systemd/system/woven-agent.service", "0644"),
        ("woven-provision.service", "/etc/systemd/system/woven-provision.service", "0644"),
        ("woven-update.service", "/etc/systemd/system/woven-update.service", "0644"),
        ("woven-egress.service", "/etc/systemd/system/woven-egress.service", "0644"),
        ("docker-archive-keyring.asc", "/etc/apt/keyrings/docker.asc", "0644")
    ]
    public static let versionsPath = "/etc/woven/versions.env"

    public static func loadVersion(resources: URL) throws -> WovenVMGuestVersion {
        try JSONDecoder().decode(WovenVMGuestVersion.self,
                                 from: Data(contentsOf: resources.appending(path: "guest-version.json")))
    }

    public static func versionsEnvironment(_ version: WovenVMGuestVersion) -> String {
        // Values are single-quoted for the shell; none of the pinned strings
        // contain quotes, and the record is reviewed in maintenance.
        """
        WOVEN_GUEST_VERSION='\(version.guestVersion)'
        DOCKER_REPOSITORY='\(version.docker.repository.absoluteString)'
        DOCKER_SUITE='\(version.docker.suite)'
        DOCKER_CE_VERSION='\(version.docker.dockerCE)'
        CONTAINERD_VERSION='\(version.docker.containerd)'

        """
    }

    /// Guest path to contents, verifying the Docker signing key against the record.
    public static func files(resources: URL, version: WovenVMGuestVersion) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for entry in layout {
            let data = try Data(contentsOf: resources.appending(path: entry.name))
            if entry.name == "docker-archive-keyring.asc" {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == version.docker.keySha256.lowercased() else {
                    throw WovenVMError.invalid("The bundled Docker signing key does not match its record.")
                }
            }
            files[entry.path] = data
        }
        files[versionsPath] = Data(versionsEnvironment(version).utf8)
        return files
    }

    public static func userData(files: [String: Data], diskCapBytes: UInt64) -> String {
        let modes = Dictionary(uniqueKeysWithValues: layout.map { ($0.path, $0.mode) })
        var entries = files.keys.sorted().map { path in
            """
              - path: \(path)
                permissions: "\(modes[path] ?? "0644")"
                encoding: b64
                content: \(files[path]!.base64EncodedString())
            """
        }
        entries.append("""
          - path: /etc/woven/disk-cap
            permissions: "0644"
            content: "\(diskCapBytes)"
        """)
        // No user, password or SSH key: the Mac reaches the guest over vsock only.
        return """
        #cloud-config
        hostname: woven-vm
        ssh_pwauth: false
        disable_root: true
        users: []
        package_update: false
        package_upgrade: false
        growpart:
          mode: auto
          devices: ["/"]
        resize_rootfs: true
        write_files:
        \(entries.joined(separator: "\n"))
        runcmd:
          - [systemctl, daemon-reload]
          - [systemctl, enable, --now, woven-agent.service]
          - [systemctl, enable, woven-provision.service, woven-egress.service]
          - [systemctl, start, --no-block, woven-provision.service]

        """
    }

    public static func metaData(instanceID: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: woven-vm\n"
    }
}

/// Follows the guest's provisioning (first boot, or Woven's update) through
/// the guest agent's `status` and decides when it has failed, so a stuck guest
/// ends as a failure naming its step instead of an endless wait.
///
/// Each step carries its own time limit (`provision.sh` reports it). The guest
/// enforces it first; the watch enforces it too, `grace` later, for a guest too
/// stuck to report (a crashed kernel can wedge every later module load). A
/// report from an earlier boot (another `boot_id`) counts as no report yet.
public struct WovenVMProvisionWatch: Sendable {
    /// One `status` reading of the provisioning (or update) state.
    public struct Report: Sendable, Equatable {
        /// `running`, `failed` or `ready`; nil before this boot's provisioning reported.
        public var phase: String?
        public var step: String?
        public var error: String?
        public var limit: TimeInterval?
        /// Done: provisioned with Docker Engine answering, or the update finished.
        public var done: Bool
        /// Provisioned, so only Docker Engine is still to answer.
        public var provisioned: Bool

        public init(phase: String? = nil, step: String? = nil, error: String? = nil, limit: TimeInterval? = nil,
                    done: Bool = false, provisioned: Bool = false) {
            self.phase = phase
            self.step = step
            self.error = error
            self.limit = limit
            self.done = done
            self.provisioned = provisioned
        }

        /// First-boot provisioning, from the agent's `status`.
        public init(provisioningIn status: [String: Any]) {
            let provisioned = status["provisioned"] is [String: Any]
            self.init(current: Self.current(status["provision"], status), provisioned: provisioned,
                      done: provisioned && status["docker"] is String)
        }

        /// Woven's update, from the agent's `status`.
        public init(updateIn status: [String: Any]) {
            let update = Self.current(status["update"], status)
            self.init(current: update, provisioned: false, done: update?["phase"] as? String == "ready")
        }

        private init(current: [String: Any]?, provisioned: Bool, done: Bool) {
            self.init(phase: current?["phase"] as? String, step: current?["step"] as? String,
                      error: current?["error"] as? String,
                      limit: (current?["timeout"] as? NSNumber)?.doubleValue,
                      done: done, provisioned: provisioned)
        }

        /// The record unless an earlier boot wrote it. An older guest's
        /// records carry no boot ID and always count.
        private static func current(_ record: Any?, _ status: [String: Any]) -> [String: Any]? {
            guard let record = record as? [String: Any] else { return nil }
            if let written = record["boot_id"] as? String, let boot = status["boot_id"] as? String, written != boot {
                return nil
            }
            return record
        }
    }

    public enum Verdict: Sendable, Equatable {
        case waiting(step: String)
        case done
        case failed(String)
    }

    /// Before this boot's provisioning first reports (cloud-init runs first).
    public static let startingLimit: TimeInterval = 600
    /// A provisioned guest's Docker Engine must answer within this.
    public static let engineLimit: TimeInterval = 300
    /// A step from an older guest that reports no limit.
    public static let unknownStepLimit: TimeInterval = 1800
    /// The guest's own limit fires first and reports the clearer reason.
    public static let grace: TimeInterval = 120
    /// The agent answered before and then stopped answering for this long.
    public static let silenceLimit: TimeInterval = 300
    public static let startingStep = "Starting the guest"
    public static let engineStep = "Waiting for Docker Engine"

    private let started: Date
    private var lastAnswer: Date?
    private var step: String?
    private var stepSince: Date

    public init(now: Date) {
        started = now
        stepSince = now
    }

    /// `report` nil: the guest agent did not answer.
    public mutating func observe(_ report: Report?, now: Date) -> Verdict {
        guard let report else {
            if let lastAnswer {
                if now.timeIntervalSince(lastAnswer) >= Self.silenceLimit {
                    return .failed("The guest stopped answering (last step: \(step ?? Self.startingStep)).")
                }
            } else if now.timeIntervalSince(started) >= Self.startingLimit {
                return .failed("The guest did not start.")
            }
            return .waiting(step: step ?? Self.startingStep)
        }
        lastAnswer = now
        if report.done { return .done }
        // `limit` is the step's own; the watch gives a guest-enforced one `grace` more.
        let current: String, limit: TimeInterval, extra: TimeInterval
        if report.provisioned {
            (current, limit, extra) = (Self.engineStep, Self.engineLimit, 0)
        } else if report.phase == "failed" {
            return .failed(report.error ?? "\(report.step ?? "Provisioning") failed.")
        } else if report.phase == nil {
            (current, limit, extra) = (Self.startingStep, Self.startingLimit, 0)
        } else if let stated = report.limit {
            (current, limit, extra) = (report.step ?? Self.startingStep, stated, Self.grace)
        } else {
            (current, limit, extra) = (report.step ?? Self.startingStep, Self.unknownStepLimit, 0)
        }
        if current != step {
            step = current
            stepSince = now
        }
        if now.timeIntervalSince(stepSince) >= limit + extra {
            return .failed("\(current) did not finish within \(Int((limit / 60).rounded())) minutes.")
        }
        return .waiting(step: current)
    }
}

/// The guest agent's `diagnostics` reply, as `WovenVMDiagnostics.guest` carries it.
public enum WovenVMGuestDiagnostics {
    /// Every item as text: strings as they are, anything else as JSON.
    public static func texts(_ reply: [String: Any]) -> [String: String] {
        reply.compactMapValues { value in
            if let text = value as? String { return text }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            else { return String(describing: value) }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The first line of a guest kernel fault (oops, BUG, soft lockup, hung
    /// task, panic) among the kernel's alert-level messages, if any.
    public static func kernelFault(_ texts: [String: String]) -> String? {
        let markers = ["Unable to handle kernel", "Internal error: Oops", "BUG:", "soft lockup",
                       "blocked for more than", "Kernel panic", "general protection fault"]
        let line = texts["kernel_alerts"]?.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in markers.contains { line.contains($0) } }
        return line.map { String($0.prefix(200)) }
    }
}

/// One reading of the guest's memory, from the guest agent's `meminfo`.
public struct WovenVMGuestMemory: Sendable, Equatable {
    public var total: UInt64
    public var available: UInt64
    /// What the balloon holds now (from the guest's balloon counters). nil from
    /// an older guest agent: the target in effect stands in for it.
    public var balloon: UInt64?
    /// Page cache waiting to be written, which the guest cannot drop yet.
    public var dirty: UInt64
    /// Cumulative time tasks stalled on memory (`/proc/pressure/memory`
    /// `some total`, microseconds). nil from an older guest agent.
    public var stallMicroseconds: UInt64?
    /// Cumulative bytes of evicted page cache read back in
    /// (`workingset_refault_file`): the cache is too small for the work.
    public var refaultBytes: UInt64?

    public init(total: UInt64, available: UInt64, balloon: UInt64? = nil, dirty: UInt64 = 0,
                stallMicroseconds: UInt64? = nil, refaultBytes: UInt64? = nil) {
        self.total = total
        self.available = available
        self.balloon = balloon
        self.dirty = dirty
        self.stallMicroseconds = stallMicroseconds
        self.refaultBytes = refaultBytes
    }

    /// Parses the agent's reply; nil when it lacks the totals.
    public init?(agentReply reply: [String: Any]) {
        func bytes(_ key: String) -> UInt64? { (reply[key] as? NSNumber)?.uint64Value }
        guard let total = bytes("total"), let available = bytes("available") else { return nil }
        let some = (reply["pressure"] as? [String: Any])?["some"] as? [String: Any]
        self.init(total: total, available: available, balloon: bytes("balloon"),
                  dirty: (bytes("dirty") ?? 0) + (bytes("writeback") ?? 0),
                  stallMicroseconds: (some?["total_us"] as? NSNumber)?.uint64Value,
                  refaultBytes: bytes("refault"))
    }
}

/// Caps the guest's memory with Virtualization's balloon.
///
/// Measured on macOS 27.2: Virtualization never discards the pages a guest
/// puts in its balloon, so the balloon cannot hand used memory back to the
/// Mac. What it can do is keep the guest from touching memory it does not
/// need: pages the guest never touched cost the Mac nothing, and the VM
/// process's footprint is the high-water mark of what the guest touched. So
/// the balloon caps the guest at what it uses (anonymous and unreclaimable
/// memory plus dirty page cache; clean page cache counts as free) plus
/// headroom, from boot on. This only works with a guest kernel that does not
/// zero pages it hands to the balloon (`init_on_alloc=0`); one that does
/// commits every ballooned page on the Mac, so the helper leaves the balloon
/// open for it. Memory the guest touched comes back only when the VM restarts,
/// which the helper does when no container has run for a while.
///
/// Taking memory from a busy guest is what hurts (a first image build
/// thrashed for 25 minutes when the balloon closed in on it), so lowering is
/// the careful direction: it waits until demand has stayed lower and the guest
/// has not been under memory pressure for a while, then steps down every few
/// seconds and stops at the first sign of pressure. Raising is immediate, and
/// any pressure (memory stalls, page cache read back as fast as it is evicted,
/// or little available memory) opens the balloon fully.
public enum WovenVMBalloonPolicy {
    /// Lowering waits for this long of steadily lower demand, so a bot's
    /// bursts do not thrash the balloon.
    public static let lowerAfter: TimeInterval = 30
    /// And for this long without memory pressure in the guest.
    public static let calmAfter: TimeInterval = 60
    /// Smaller differences are left alone.
    public static let lowerThreshold: UInt64 = 256 << 20
    /// Lowering steps down by at most this much every `lowerInterval`, so
    /// pressure stops it before it goes far.
    public static let lowerStep: UInt64 = 1 << 30
    public static let lowerInterval: TimeInterval = 5
    /// The balloon's own reclaim right after a step counts as a stall; stalls
    /// this soon after a step are its doing, not the guest's.
    public static let stepGrace: TimeInterval = 3
    /// Stalled time per second at or above which the guest is under memory
    /// pressure (1%: reclaim is costing it real time).
    public static let pressureStallPerSecond: Double = 10_000
    /// Page cache read back per second at or above which the cap is too small
    /// for the work (an image build re-reading its layers).
    public static let pressureRefaultPerSecond: Double = Double(8 << 20)
    public static let floor: UInt64 = 1536 << 20
    /// Pool changes and booting start from this much above the floor.
    public static let bootDemand: UInt64 = 1 << 30

    public static func headroom(ceiling: UInt64) -> UInt64 { max(1 << 30, ceiling / 4) }

    /// The cap a VM boots with: enough for the guest and Docker to start
    /// (it opens at once under pressure).
    public static func bootTarget(ceiling: UInt64) -> UInt64 {
        mib(min(ceiling, max(floor, bootDemand + headroom(ceiling: ceiling))))
    }

    public struct State: Sendable, Equatable {
        /// The target in effect; nil is the ceiling (balloon open).
        public var target: UInt64?
        /// When demand first stayed lower than the target.
        public var lowerSince: Date?
        /// The last time the guest was under memory pressure.
        public var pressureAt: Date?
        /// The last lowering step.
        public var steppedAt: Date?
        var last: Sample?
        public init(target: UInt64? = nil, lowerSince: Date? = nil, pressureAt: Date? = nil, steppedAt: Date? = nil) {
            self.target = target
            self.lowerSince = lowerSince
            self.pressureAt = pressureAt
            self.steppedAt = steppedAt
        }
    }

    struct Sample: Sendable, Equatable {
        var at: Date
        var stall: UInt64?
        var refault: UInt64?
    }

    public struct Decision: Sendable, Equatable {
        public var target: UInt64
        /// What the guest needs, without the balloon.
        public var demand: UInt64
        public var underPressure: Bool
    }

    /// What the guest needs: used memory minus what the balloon holds (with
    /// deflate-on-OOM, Linux counts ballooned pages as used), plus dirty pages.
    public static func demand(_ memory: WovenVMGuestMemory, booted: UInt64, target: UInt64) -> UInt64 {
        let ballooned = memory.balloon ?? (booted > target ? booted - target : 0)
        let used = memory.total > memory.available ? memory.total - memory.available : 0
        return (used > ballooned ? used - ballooned : 0) + memory.dirty
    }

    /// One tick: the new target, given a fresh reading.
    public static func step(_ state: inout State, memory: WovenVMGuestMemory, ceiling: UInt64,
                            booted: UInt64, now: Date) -> Decision {
        let ceiling = mib(ceiling)
        let current = min(state.target ?? ceiling, ceiling)
        let need = demand(memory, booted: booted, target: current)
        let headroom = headroom(ceiling: ceiling)

        let sample = Sample(at: now, stall: memory.stallMicroseconds, refault: memory.refaultBytes)
        var stalled = false, thrashing = false
        if let last = state.last, now > last.at {
            let seconds = now.timeIntervalSince(last.at)
            func rate(_ new: UInt64?, _ old: UInt64?) -> Double {
                guard let new, let old, new >= old else { return 0 }
                return Double(new - old) / seconds
            }
            let ownReclaim = state.steppedAt.map { now.timeIntervalSince($0) < stepGrace } ?? false
            stalled = !ownReclaim && rate(sample.stall, last.stall) >= pressureStallPerSecond
            thrashing = rate(sample.refault, last.refault) >= pressureRefaultPerSecond
        }
        state.last = sample
        // Available memory counts what the balloon holds as used, so this is
        // what the guest can still get without the balloon giving any back.
        let starved = memory.available < headroom / 2
        if stalled || thrashing || starved {
            state.pressureAt = now
            state.lowerSince = nil
            state.target = ceiling
            return Decision(target: ceiling, demand: need, underPressure: true)
        }

        let desired = mib(min(ceiling, max(min(ceiling, floor), need + headroom)))
        if desired >= current {
            state.lowerSince = nil
            state.target = desired
            return Decision(target: desired, demand: need, underPressure: false)
        }
        guard current - desired >= lowerThreshold else {
            state.lowerSince = nil
            return Decision(target: current, demand: need, underPressure: false)
        }
        let since = state.lowerSince ?? now
        state.lowerSince = since
        let calm = state.pressureAt.map { now.timeIntervalSince($0) >= calmAfter } ?? true
        let spaced = state.steppedAt.map { now.timeIntervalSince($0) >= lowerInterval } ?? true
        guard calm, spaced, now.timeIntervalSince(since) >= lowerAfter else {
            return Decision(target: current, demand: need, underPressure: false)
        }
        let target = max(desired, current - min(lowerStep, current - desired))
        state.target = target
        state.steppedAt = now
        return Decision(target: target, demand: need, underPressure: false)
    }

    /// The guest agent did not answer in time: open the balloon.
    public static func unanswered(_ state: inout State, ceiling: UInt64, now: Date) -> UInt64 {
        state.pressureAt = now
        state.lowerSince = nil
        state.last = nil
        state.target = mib(ceiling)
        return mib(ceiling)
    }

    /// The guest kernel's command line: whether it leaves pages it hands to the
    /// balloon untouched. Ubuntu's kernel zeroes every allocation by default.
    public static func guestLeavesBalloonUntouched(commandLine: String) -> Bool {
        let options = commandLine.split(whereSeparator: \.isWhitespace)
        // The last occurrence wins, as in the kernel.
        guard let last = options.last(where: { $0.hasPrefix("init_on_alloc=") }) else { return false }
        return ["0", "off", "n", "no", "false"].contains(last.dropFirst("init_on_alloc=".count).lowercased())
    }

    /// Whether to restart an idle VM to give the memory its guest once touched
    /// back to the Mac: the footprint stands well above what the guest is
    /// capped at, and no container has run for `idleRestartAfter`.
    public static let idleRestartAfter: TimeInterval = 600
    public static let idleRestartSpacing: TimeInterval = 1800
    public static func shouldRestartIdle(footprint: UInt64, target: UInt64, idleSince: Date?,
                                         lastRestart: Date?, now: Date) -> Bool {
        guard let idleSince, now.timeIntervalSince(idleSince) >= idleRestartAfter else { return false }
        if let lastRestart, now.timeIntervalSince(lastRestart) < idleRestartSpacing { return false }
        // The margin covers the VM process's own memory and the guest's boot.
        return footprint > target + (1 << 30)
    }

    /// Memory the running VM may use: the boot size, or a lower pool applied
    /// live until the next restart.
    public static func ceiling(bootedBytes: UInt64, requestedBytes: UInt64) -> UInt64 {
        min(bootedBytes, max(requestedBytes, WovenVMResources.minimumMemoryBytes))
    }

    /// VZ needs whole MiB.
    static func mib(_ bytes: UInt64) -> UInt64 { bytes / (1 << 20) * (1 << 20) }
}

/// Size limits shared by the helper and the app's settings validation.
public enum WovenVMSizing {
    /// VZ needs whole MiB.
    public static func memoryBytes(requested: UInt64?, physical: UInt64, maximumAllowed: UInt64) -> UInt64 {
        let wanted = min(requested ?? physical, physical, maximumAllowed)
        let clamped = max(wanted, WovenVMResources.minimumMemoryBytes)
        return clamped / (1 << 20) * (1 << 20)
    }

    public static func validate(_ resources: WovenVMResources, physicalMemory: UInt64, diskTotal: UInt64) throws {
        if let memory = resources.memoryBytes {
            guard memory >= WovenVMResources.minimumMemoryBytes, memory <= physicalMemory else {
                throw WovenVMError.invalid("The RAM pool must be between 1 GB and this Mac's memory.")
            }
        }
        if let disk = resources.diskBytes {
            guard disk >= WovenVMResources.minimumDiskBytes, disk <= diskTotal else {
                throw WovenVMError.invalid("The bot disk cap must be between 10 GB and the disk's size.")
            }
        }
    }
}
#endif
