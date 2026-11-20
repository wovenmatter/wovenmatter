import Foundation

/// The Woven server on one machine, as Settings shows it.
struct MachineServerStatus: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case running
        case stopped
        case unavailable

        var displayName: String {
            switch self {
            case .running: "Running"
            case .stopped: "Stopped"
            case .unavailable: "Server unavailable"
            }
        }
    }

    var state: State
    /// How the server was installed on a Linux machine.
    var accessMode: LinuxAccessMode?
    var userName: String?
    var hostName: String?
    var health: String?
    var storageUsedBytes: Int64?
    var hostStorageCapacityBytes: Int64?
    var hostStorageAvailableBytes: Int64?
    var storageWarning: String?

    var isRunning: Bool { state == .running }
}

/// Whether the server on a Linux machine runs agents as root or as its user.
enum LinuxAccessMode: String, CaseIterable, Hashable, Sendable {
    case fullRoot
    case user

    var displayName: String {
        switch self {
        case .fullRoot: "Full root access"
        case .user: "Normal user permissions"
        }
    }
}

/// Stopping a server with active work asks first.
struct ServerStopResult: Hashable, Sendable {
    var confirmationRequired: Bool
}

/// Whether the browser agents use can start in its sandbox on that machine.
struct BrowserSandboxCheck: Hashable, Sendable {
    var ok: Bool
    var reason: String?
    var missingLibraries: [String] = []
    var hint: String?
}

/// A computer on the tailnet that does not run the Woven server yet. Find Devices lists
/// these and installs the server over SSH.
struct TailnetDevice: Identifiable, Hashable, Sendable {
    enum Installation: Hashable, Sendable {
        case unknown
        case notInstalled
        /// The app is there but its server is not running.
        case installed(version: String?)
    }

    let id: String
    var name: String
    var hostName: String
    var address: String
    var platform: Machine.Platform
    var isOnline: Bool
    var installation: Installation = .unknown
}

/// What inspecting a Linux host over SSH found, before installing the server there.
struct HostPreflight: Hashable, Sendable {
    var hostName: String
    var ready: Bool
    var architecture: String
    var limitations: [String] = []
    var hostStorageCapacityBytes: Int64?
    var hostStorageAvailableBytes: Int64?
    var storageWarning: String?
    var canPrepare: Bool
    var preparationActions: [String] = []

    var preparationRequired: Bool { !preparationActions.isEmpty }
}

/// What a server is running right now. Saved history never proves a process is alive.
struct RuntimeInspection: Hashable, Sendable {
    struct Item: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case service
            case runtime
            case conversation
            case subagent
            case tool
            case scheduler
            case process

            var displayName: String {
                switch self {
                case .service: "Service"
                case .runtime: "Runtime"
                case .conversation: "Conversation"
                case .subagent: "Subagent"
                case .tool: "Tool"
                case .scheduler: "Scheduler"
                case .process: "Process"
                }
            }

            var systemImage: String {
                switch self {
                case .service: "server.rack"
                case .conversation: "bubble.left"
                case .subagent: "person.2"
                case .tool: "wrench"
                case .scheduler: "clock"
                case .runtime, .process: "terminal"
                }
            }
        }

        let id: String
        var parentID: String?
        var sessionID: String?
        var kind: Kind
        var title: String
        var state: String
        var processID: Int32?
        var detail: String?
        var cpuPercent: Double?
        var residentBytes: Int64?
    }

    var observedAt: Date
    var items: [Item]
}

/// Services first, then one group per agent session, then everything else.
struct RuntimeInspectionInventory {
    struct Agent: Identifiable {
        let id: String
        let summary: RuntimeInspection.Item
        let details: [RuntimeInspection.Item]
    }

    let servers: [RuntimeInspection.Item]
    let agents: [Agent]
    let otherProcesses: [RuntimeInspection.Item]

    init(items: [RuntimeInspection.Item]) {
        var indexed: [String: RuntimeInspection.Item] = [:]
        for item in items { indexed[item.id] = item }
        let ordered = indexed.values.sorted { $0.id < $1.id }
        servers = ordered.filter { $0.kind == .service }
        var grouped: [String: [RuntimeInspection.Item]] = [:], other: [RuntimeInspection.Item] = []
        func agentKey(_ item: RuntimeInspection.Item) -> String? {
            var candidate: RuntimeInspection.Item? = item, seen = Set<String>(), runtime: String?
            while let current = candidate, seen.insert(current.id).inserted {
                if let session = current.sessionID { return "session:" + session }
                if current.kind == .conversation { return current.id }
                if current.kind == .runtime, runtime == nil { runtime = current.id }
                candidate = current.parentID.flatMap { indexed[$0] }
            }
            return runtime
        }
        for item in ordered where item.kind != .service {
            if let key = agentKey(item) { grouped[key, default: []].append(item) } else { other.append(item) }
        }
        agents = grouped.map { key, members in
            let summary = members.first { $0.kind == .conversation }
                ?? members.first { $0.kind == .runtime } ?? members[0]
            return Agent(id: key, summary: summary, details: members.filter { $0.id != summary.id })
        }.sorted { $0.summary.title == $1.summary.title ? $0.id < $1.id : $0.summary.title < $1.summary.title }
        otherProcesses = other
    }
}

/// When to keep a Mac awake while agent work runs, by power source.
struct WorkPowerPolicy: Hashable, Sendable {
    var externalPower = false
    var batteryPower = false

    var isEnabled: Bool { externalPower || batteryPower }
}

/// This Mac's screen-sleep and closed-lid protection, as its server reports it.
struct MachinePower: Hashable, Sendable {
    /// Whether macOS lets the server's power helper run.
    enum ClosedLidHelper: Hashable, Sendable {
        case ready
        case approvalRequired
        case notRegistered
        case unavailable(reason: String)
    }

    var idleSleep = WorkPowerPolicy(externalPower: true, batteryPower: true)
    var closedLid = WorkPowerPolicy()
    var closedLidHelper: ClosedLidHelper = .notRegistered
    var isProtectingClosedLid = false
    var closedLidMessage: String?
}

/// OpenCode's own background server on one machine, and the models Woven shows from it.
struct OpenCodeServer: Hashable, Sendable {
    enum State: Hashable, Sendable { case ready, connecting, notConnected }

    var state: State = .notConnected
    var isInstalled = false
    var isInstalling = false
    var isControllingServer = false
    var hasServer = false
    var startsWithApp = true
    /// The name of its agent in the sidebar.
    var agentName: String
    /// Set when installing OpenCode 2 would replace OpenCode 1's command there.
    var replacesVersionOne: String?
    var models: [OpenCodeModelOption] = []
    var hiddenModels: Set<String> = []

    var isReady: Bool { state == .ready }
}

struct OpenCodeModelOption: Identifiable, Hashable, Sendable {
    /// `provider/model`, the key visibility is saved under.
    let id: String
    var name: String
    var providerID: String
}

/// OpenCode sessions on a machine that can be added to Woven's chats.
struct OpenCodeSessionPage: Hashable, Sendable {
    struct Session: Identifiable, Hashable, Sendable {
        let id: String
        var title: String
        var directory: String
    }

    var sessions: [Session]
    var next: String?
}
