import Foundation

/// How a Woven app reaches one machine's bots runtime: the loopback socket on this
/// Mac with its runtime bearer, or another member's Woven server at `/v1/bots/ws`
/// with a member signature addressed to `audience` (that machine's member device ID;
/// a fresh signature for every connection, so `bearer` is empty).
public struct BotSocketEndpoint: Codable, Equatable, Sendable, CustomStringConvertible {
    public var url: URL
    public var bearer: String
    public var audience: String?
    public init(url: URL, bearer: String, audience: String? = nil) { self.url = url; self.bearer = bearer; self.audience = audience }
    /// Another member's server, reached with signed upgrades.
    public static func signed(_ url: URL, audience: String) -> BotSocketEndpoint { .init(url: url, bearer: "", audience: audience) }
    public var isSigned: Bool { audience != nil }
    /// Never print the bearer.
    public var description: String { "BotSocketEndpoint(\(url.absoluteString))" }
}

public struct BotMachineVersions: Codable, Equatable, Sendable {
    /// The Woven Matter app on a Mac. On Linux, the Woven Matter version whose app shipped
    /// the host release (nil for a release that predates recording it).
    public var app: String?
    public var runtime: String?
    public var `protocol`: Int?
    /// A Linux host's release fingerprint: the SHA-256 `remote-host.sh install` verified.
    /// It changes with any host source, the library binaries included.
    public var fingerprint: String?
    /// The library host's paired-library schema hash, when its library reports one. Sync
    /// between two devices needs equal schemas.
    public var librarySchema: String?
    public init(app: String? = nil, runtime: String? = nil, protocol: Int? = nil,
                fingerprint: String? = nil, librarySchema: String? = nil) {
        self.app = app; self.runtime = runtime; self.protocol = `protocol`
        self.fingerprint = fingerprint; self.librarySchema = librarySchema
    }
}

/// One machine whose Woven server hosts, or can host, bots.
public struct BotMachine: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case thisMac, mac, linux }
    public enum State: String, Codable, Sendable {
        /// Bots are not turned on for this machine.
        case off
        case starting
        case ready
        /// Offline, or its Woven server did not answer.
        case unreachable
        /// Its versions differ from this Mac's, so it cannot be used until updated.
        case needsUpdate
        case failed
    }

    /// The machine's Woven device ID, the middle of every bot principal it issues.
    public var id: String
    public var name: String
    public var kind: Kind
    public var state: State
    public var message: String?
    public var socket: BotSocketEndpoint?
    public var versions: BotMachineVersions
    public var resources: BotResourceSettings?
    public var capacity: BotMachineCapacity?
    /// Every bot here is paused from Woven MCP.
    public var paused: Bool
    /// A bots update or rebuild is running, or the machine's bots engine is updating.
    public var updating: Bool
    /// Why the machine's last bots engine update (the Mac VM) failed and was rolled back.
    public var engineUpdateFailure: String?

    public init(id: String, name: String, kind: Kind, state: State, message: String? = nil, socket: BotSocketEndpoint? = nil,
                versions: BotMachineVersions = .init(), resources: BotResourceSettings? = nil, capacity: BotMachineCapacity? = nil,
                paused: Bool = false, updating: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.state = state; self.message = message; self.socket = socket
        self.versions = versions; self.resources = resources; self.capacity = capacity; self.paused = paused; self.updating = updating
    }

    public var displayName: String { kind == .thisMac ? "This Mac" : name }
}

/// `GET /v1/bots/status` on any machine's Woven server, and the body of
/// `POST /v1/bots/resources`'s reply. Linux hosts and Macs answer with the same shape.
public struct BotsRemoteStatus: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public var deviceID: String
        public var name: String
        /// `mac` or `linux`.
        public var kind: String
        public init(deviceID: String, name: String, kind: String) { self.deviceID = deviceID; self.name = name; self.kind = kind }
    }
    public var machine: Machine
    public var enabled: Bool
    /// `off`, `starting`, `ready` or `failed`.
    public var state: String
    public var message: String?
    public var versions: BotMachineVersions
    public var resources: BotResourceSettings?
    public var capacity: BotMachineCapacity?
    public var paused: Bool?
    /// The machine's bots engine is updating (Macs; absent from older servers).
    public var updating: Bool?
    public var engineUpdateFailure: String?

    public init(machine: Machine, enabled: Bool, state: String, message: String? = nil, versions: BotMachineVersions,
                resources: BotResourceSettings? = nil, capacity: BotMachineCapacity? = nil, paused: Bool? = nil) {
        self.machine = machine; self.enabled = enabled; self.state = state; self.message = message; self.versions = versions
        self.resources = resources; self.capacity = capacity; self.paused = paused
    }

    /// The machine as the Bots UI lists it, reached through `socket`. `expectedHostFingerprint`
    /// is the host release this Mac would install (its bundled host sources): a Linux host on
    /// any other release is out of date, whatever version it names.
    public func machine(kind: BotMachine.Kind, socket: BotSocketEndpoint?, thisMacVersion: String?,
                        expectedHostFingerprint: String? = nil) -> BotMachine {
        let base: BotMachine.State = switch state { case "ready": .ready; case "starting": .starting; case "failed": .failed; default: .off }
        let mismatch = Self.mismatch(kind: kind, versions: versions, thisMacVersion: thisMacVersion,
                                     expectedHostFingerprint: expectedHostFingerprint)
        var result = BotMachine(id: machine.deviceID, name: machine.name, kind: kind, state: mismatch == nil ? base : .needsUpdate,
                                message: mismatch ?? message,
                                socket: enabled ? socket : nil, versions: versions, resources: resources, capacity: capacity,
                                paused: paused ?? false, updating: updating ?? false)
        result.engineUpdateFailure = engineUpdateFailure
        return result
    }

    /// Why a machine cannot be used until it is updated, or nil when it matches this Mac.
    static func mismatch(kind: BotMachine.Kind, versions: BotMachineVersions, thisMacVersion: String?,
                         expectedHostFingerprint: String?) -> String? {
        guard kind != .thisMac else { return nil }
        if kind == .linux, let expected = expectedHostFingerprint, versions.fingerprint != expected {
            if let app = versions.app, let ours = thisMacVersion, app != ours {
                return "Runs Woven Matter \(app) and this Mac runs \(ours). Update everything to use its bots."
            }
            return "Runs a different Woven host release than this Mac's. Update everything to use its bots."
        }
        if let app = versions.app, let ours = thisMacVersion, app != ours, versions.fingerprint == nil || expectedHostFingerprint == nil {
            return "Runs Woven Matter \(app) and this Mac runs \(ours). Update everything to use its bots."
        }
        return nil
    }
}

// MARK: - Resources

/// Byte counts for one machine's bots. nil means no cap.
public struct BotResourceSettings: Codable, Equatable, Sendable {
    public static let gib: Int64 = 1 << 30
    public static let defaults = BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 50 * gib)

    /// The memory every bot on the machine shares: the VM on a Mac, the engine's slice on Linux.
    public var poolBytes: Int64?
    /// Each bot's container memory limit.
    public var perBotBytes: Int64?
    /// One total cap on bot storage.
    public var diskBytes: Int64?

    public init(poolBytes: Int64?, perBotBytes: Int64?, diskBytes: Int64?) {
        self.poolBytes = poolBytes; self.perBotBytes = perBotBytes; self.diskBytes = diskBytes
    }

    private enum CodingKeys: String, CodingKey { case poolBytes, perBotBytes, diskBytes }
    /// No cap travels as an explicit null, never as a missing field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(poolBytes, forKey: .poolBytes)
        try container.encode(perBotBytes, forKey: .perBotBytes)
        try container.encode(diskBytes, forKey: .diskBytes)
    }
}

public struct BotMachineCapacity: Codable, Equatable, Sendable {
    public var memoryBytes: Int64
    public var diskTotalBytes: Int64
    public var diskFreeBytes: Int64
    /// What bots already store; lowering the disk cap stops here.
    public var diskUsedByBotsBytes: Int64?
    public init(memoryBytes: Int64, diskTotalBytes: Int64, diskFreeBytes: Int64, diskUsedByBotsBytes: Int64? = nil) {
        self.memoryBytes = memoryBytes; self.diskTotalBytes = diskTotalBytes; self.diskFreeBytes = diskFreeBytes
        self.diskUsedByBotsBytes = diskUsedByBotsBytes
    }
}

/// The rules in Settings → Bots → Resources, without any view.
public enum BotResourcePolicy {
    public static let gib = BotResourceSettings.gib
    /// Below this much memory left over, the device itself suffers.
    public static let deviceReserveBytes: Int64 = 4 * gib

    public enum Warning: Equatable, Sendable {
        case poolLeavesLittleMemory(leftBytes: Int64)
        case diskCapExceedsFree(freeBytes: Int64)
    }

    /// Whole gigabytes from 1 GB to the device's memory.
    public static func poolChoices(_ capacity: BotMachineCapacity) -> [Int64] {
        stride(from: gib, through: max(gib, capacity.memoryBytes / gib * gib), by: Int(gib)).map { $0 }
    }

    /// Whole gigabytes up to the pool, or up to the device's memory with no pool cap.
    public static func perBotChoices(pool: Int64?, _ capacity: BotMachineCapacity) -> [Int64] {
        let ceiling = pool ?? max(gib, capacity.memoryBytes / gib * gib)
        return stride(from: gib, through: max(gib, ceiling), by: Int(gib)).map { $0 }
    }

    public static func diskChoices(_ capacity: BotMachineCapacity) -> [Int64] {
        let total = max(gib, capacity.diskTotalBytes / gib * gib)
        var values: [Int64] = [5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 4_000].map { $0 * gib }.filter { $0 <= total }
        if values.last != total { values.append(total) }
        return values
    }

    /// The defaults, fitted to a machine smaller than they assume.
    public static func defaults(for capacity: BotMachineCapacity) -> BotResourceSettings {
        validated(.defaults, capacity)
    }

    /// Brings every value inside its range: the pool within 1 GB…device memory, per-bot within
    /// the pool, and disk within the disk's size and at least what bots already use.
    public static func validated(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> BotResourceSettings {
        var result = settings
        let memory = max(gib, capacity.memoryBytes)
        if let pool = result.poolBytes { result.poolBytes = min(max(gib, pool), memory) }
        if let perBot = result.perBotBytes { result.perBotBytes = min(max(gib, perBot), result.poolBytes ?? memory) }
        if let disk = result.diskBytes {
            let floor = max(gib, capacity.diskUsedByBotsBytes ?? 0)
            result.diskBytes = min(max(floor, disk), max(floor, capacity.diskTotalBytes))
        }
        return result
    }

    public static func warnings(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> [Warning] {
        var result: [Warning] = []
        // No cap can take everything, so it leaves the device nothing it can count on.
        let left = capacity.memoryBytes - (settings.poolBytes ?? capacity.memoryBytes)
        if left < deviceReserveBytes { result.append(.poolLeavesLittleMemory(leftBytes: max(0, left))) }
        if (settings.diskBytes ?? Int64.max) > capacity.diskFreeBytes + (capacity.diskUsedByBotsBytes ?? 0) {
            result.append(.diskCapExceedsFree(freeBytes: capacity.diskFreeBytes))
        }
        return result
    }

    public static func text(_ warning: Warning) -> String {
        switch warning {
        case .poolLeavesLittleMemory(let left):
            "This leaves \(format(left)) for everything else on this device. Keep at least 4 GB free."
        case .diskCapExceedsFree(let free):
            "This is more than the \(format(free)) free on this disk. Bots stop saving files when the disk fills."
        }
    }

    public static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "No cap" }
        let gigabytes = Double(bytes) / Double(gib)
        if gigabytes >= 1_000 { return String(format: gigabytes.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0f TB" : "%.1f TB", gigabytes / 1_000) }
        if gigabytes >= 10 || gigabytes.rounded() == gigabytes { return String(format: "%.0f GB", gigabytes.rounded()) }
        return String(format: "%.1f GB", gigabytes)
    }
}

// MARK: - Discovery

/// An online tailnet peer and what it needs before it can run bots.
public struct BotDiscoveredDevice: Codable, Equatable, Identifiable, Sendable {
    public enum System: String, Codable, Sendable { case macOS, linux }
    public enum State: Codable, Equatable, Sendable {
        /// Linux without a Woven server: install the bots-only host (sudo once).
        case installBots
        /// A Mac without the app, or not yet connected on Mac connections.
        case installApp
        /// Its Woven server answers; its bots appear in the list.
        case ready
        case installing(String)
        case failed(String)
    }
    public var id: String { hostName }
    public let hostName: String
    public let displayName: String
    public let dnsName: String?
    public let system: System
    public var state: State

    public init(hostName: String, displayName: String, dnsName: String?, system: System, state: State) {
        self.hostName = hostName; self.displayName = displayName; self.dnsName = dnsName; self.system = system; self.state = state
    }

    /// The steps shown for a Mac that cannot host bots yet.
    public static let macSetupSteps = [
        "Download Woven Matter on that Mac from wovenmatter.com.",
        "Open it.",
        "On this Mac, connect it in Settings → Apple Devices → Mac connections.",
        "Finish the setup card on that Mac.",
    ]
}

// MARK: - Versions and updates

/// What Settings and the Bots page say about mismatched versions.
public struct BotVersionReport: Equatable, Sendable {
    public struct Part: Equatable, Identifiable, Sendable {
        public enum Kind: String, Equatable, Sendable { case thisMac, mac, linux, bots }
        public let id: String
        public let kind: Kind
        public let name: String
        public let current: String?
        public let expected: String?
    }
    /// Parts whose version differs from this Mac's.
    public let outdated: [Part]
    /// Library sync stopped because of a schema mismatch.
    public let syncStopped: Bool

    public init(thisMacVersion: String?, machines: [BotMachine], syncErrors: [String] = []) {
        var parts: [Part] = []
        for machine in machines where machine.kind != .thisMac {
            if let app = machine.versions.app, let thisMacVersion, app != thisMacVersion {
                parts.append(.init(id: machine.id, kind: machine.kind == .mac ? .mac : .linux, name: machine.name,
                                   current: app, expected: thisMacVersion))
            } else if machine.kind == .linux, machine.state == .needsUpdate {
                // Same version name, different release (or one too old to say): name the releases.
                parts.append(.init(id: machine.id, kind: .linux, name: machine.name,
                                   current: machine.versions.fingerprint.map { "release " + $0.prefix(8) } ?? machine.versions.app ?? "an older release",
                                   expected: thisMacVersion ?? "this Mac's release"))
            }
        }
        let runtimes = Set(machines.compactMap(\.versions.runtime))
        if runtimes.count > 1, let newest = runtimes.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            for machine in machines where machine.versions.runtime.map({ $0 != newest }) == true {
                parts.append(.init(id: "bots:" + machine.id, kind: .bots, name: machine.displayName,
                                   current: machine.versions.runtime, expected: newest))
            }
        }
        outdated = parts
        syncStopped = syncErrors.contains { Self.isVersionMismatch($0) }
    }

    public var needsUpdate: Bool { !outdated.isEmpty || syncStopped }

    public var message: String? {
        guard needsUpdate else { return nil }
        if syncStopped {
            return "Library sync stopped because your devices run different versions. Update everything to resume it."
        }
        let names = outdated.map(\.name)
        let list = names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) \(names.count == 1 ? "runs" : "run") a different version. Update everything so every device matches."
    }

    /// Peer sync rejects a schema mismatch with this wording (`PairedLibraryStore`).
    public static func isVersionMismatch(_ error: String) -> Bool {
        error.localizedCaseInsensitiveContains("same Woven Matter version") || error.localizedCaseInsensitiveContains("schema")
    }
}

/// "Update everything": other machines first, then each Mac's bots engine (the VM) and then
/// its bots, then this Mac's app, which restarts. A machine already on this Mac's release is
/// skipped; `runtime.update` is a no-op for bots already on their runtime's current image.
public enum BotUpdatePlan {
    public enum Step: Equatable, Sendable {
        case linuxHost(id: String, name: String)
        case mac(id: String, name: String)
        /// A Mac's Woven VM, before its bots: `runtime.update` then runs on the updated engine.
        /// A Linux host's engine updates with the host itself.
        case engine(machineID: String, name: String)
        case bots(machineID: String, name: String)
        case thisMacApp
    }

    public static func steps(machines: [BotMachine], thisMacVersion: String?) -> [Step] {
        let others = machines.filter { $0.kind != .thisMac && $0.state != .unreachable }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var steps: [Step] = others.compactMap { machine in
            if machine.kind == .linux {
                // The fingerprint is exact: a host on this Mac's release has nothing to update.
                let current = machine.versions.fingerprint != nil ? machine.state != .needsUpdate
                    : machine.versions.app != nil && machine.versions.app == thisMacVersion
                return current ? nil : .linuxHost(id: machine.id, name: machine.name)
            }
            guard machine.versions.app == nil || machine.versions.app != thisMacVersion else { return nil }
            if let theirs = machine.versions.app, let ours = thisMacVersion, isNewer(theirs, than: ours) { return nil }
            return .mac(id: machine.id, name: machine.name)
        }
        for machine in machines where machine.state == .ready || machine.state == .needsUpdate {
            if machine.kind != .linux { steps.append(.engine(machineID: machine.id, name: machine.displayName)) }
            steps.append(.bots(machineID: machine.id, name: machine.displayName))
        }
        if thisMacNeedsUpdate(machines: machines, thisMacVersion: thisMacVersion) { steps.append(.thisMacApp) }
        return steps
    }

    /// Another Mac already runs a newer Woven Matter than this one.
    public static func thisMacNeedsUpdate(machines: [BotMachine], thisMacVersion: String?) -> Bool {
        guard let ours = thisMacVersion else { return false }
        return machines.contains { $0.kind == .mac && $0.versions.app.map { isNewer($0, than: ours) } == true }
    }

    public static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }
}

public enum BotsError: LocalizedError, Sendable, Equatable {
    case notConnected
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: "Bots are not connected."
        case .unavailable(let detail): detail
        }
    }
}
