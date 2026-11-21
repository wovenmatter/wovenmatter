import Foundation
import WovenProtocol

/// A Mac or Linux machine on the person's tailnet that runs the Woven server.
/// This Mac is one of them. A machine that is switched off stays listed, offline.
struct Machine: Identifiable, Hashable, Sendable {
    enum Platform: String, Hashable, Sendable {
        case mac
        case linux

        var displayName: String {
            switch self {
            case .mac: "Mac"
            case .linux: "Linux"
            }
        }

        var systemImage: String {
            switch self {
            case .mac: "laptopcomputer"
            case .linux: "server.rack"
            }
        }
    }

    /// Permanent identifier, created by the machine's server on first start.
    let id: String
    /// Starts as the tailnet name; can be renamed, and the name syncs.
    var name: String
    var platform: Platform
    var isThisMachine: Bool
    var isOnline: Bool
    /// The app release it last reported, when it has been reached.
    var appVersion: String?
    /// The runtimes installed there that can start a session.
    var runtimes: [AgentRuntimeKind]

    func canRun(_ runtime: AgentRuntimeKind) -> Bool { runtimes.contains(runtime) }
}

/// The runtimes a session can run on. Bots are not here: they have their own
/// surface on the bots' host.
enum AgentRuntimeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case defaultAgent = "default_agent"
    case codex
    case claudeCode = "claude_code"
    case grokBuild = "grok_build"
    case opencode

    static let presentationOrder: [Self] = allCases

    /// The UI's kind for a runtime the server names; nil for one the UI does not offer.
    init?(runtime: RuntimeKind) {
        switch runtime {
        case .piDurable: self = .defaultAgent
        case .codex: self = .codex
        case .claudeCode: self = .claudeCode
        case .grokBuild: self = .grokBuild
        case .openCode: self = .opencode
        default: return nil
        }
    }

    /// The server's name for this runtime.
    var runtime: RuntimeKind {
        switch self {
        case .defaultAgent: .piDurable
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .grokBuild: .grokBuild
        case .opencode: .openCode
        }
    }

    var presentationRank: Int {
        Self.presentationOrder.firstIndex(of: self) ?? Self.presentationOrder.count
    }

    var displayName: String {
        switch self {
        case .defaultAgent: "Pi Durable"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .grokBuild: "Grok Build"
        case .opencode: "OpenCode"
        }
    }

    /// The harness's native Full access mode: the default for every new chat.
    var fullAccessPermission: String? {
        switch self {
        case .codex: "agent-full-access"
        case .claudeCode, .grokBuild: "bypassPermissions"
        case .defaultAgent: "full"
        case .opencode: "allow"
        }
    }

    /// The harness's native auto mode, where it has one.
    var autoPermission: String? {
        switch self {
        case .codex: "agent"
        case .claudeCode, .grokBuild: "auto"
        case .defaultAgent, .opencode: nil
        }
    }

    /// The only permission modes offered, Full access first.
    var supportedPermissions: [String] {
        [fullAccessPermission, autoPermission].compactMap { $0 }
    }

    func supportsPermission(_ id: String) -> Bool { supportedPermissions.contains(id) }

    func supportedPermission(_ id: String?) -> String? {
        id.flatMap { supportsPermission($0) ? $0 : nil }
    }

    func orderedPermissionOptions(_ options: [String]) -> [String] {
        supportedPermissions.filter(options.contains)
    }
}

/// One runtime on one machine, as the sidebar lists it under that machine's Agents.
struct WorkspaceAgent: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var iconKey: String
    let runtimeKind: AgentRuntimeKind
    /// The machine that runs it. Sessions started from it run there.
    let machineID: String
    var status: Status

    enum Status: String, Hashable, Sendable {
        case ready
        case running
        case needsAuthentication
        case offline
        case failed
    }

    static func id(machineID: String, runtime: AgentRuntimeKind) -> String { machineID + "/" + runtime.rawValue }
}
