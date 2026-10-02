import Foundation

/// Public preferences only. Manager keys and scoped grants never enter the workspace database.
public struct ExecutorConfiguration: Codable, Equatable, Sendable {
    public enum Location: String, CaseIterable, Codable, Sendable { case local, remote }
    public var id: String = UUID().uuidString.lowercased()
    public var location: Location = .local
    public var host: String = ""
    public var user: String = ""
    public var origin: String = ""
    public var apps: [ExecutorAppProfile] = []
    public var defaultProfiles: Set<String> = []
    public init() {}
}

public struct ExecutorSetupState: Codable, Equatable, Sendable {
    public var configuration: ExecutorConfiguration
    public var running: Bool
    public var error: String?
    public init(configuration: ExecutorConfiguration, running: Bool, error: String? = nil) {
        self.configuration = configuration; self.running = running; self.error = error
    }
}

public struct ExecutorAppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var app: String
    public var name: String
    public var profile: String
    public var profileName: String
    public init(id: String, app: String, name: String, profile: String, profileName: String) {
        self.id = id; self.app = app; self.name = name; self.profile = profile; self.profileName = profileName
    }
}

/// Interpret confirmed wire values, never labels or agent-supplied CLI options.
/// Native smart reviewers cannot be invoked for an arbitrary gateway callback;
/// those callbacks use the normal manual request UI instead of bypassing review.
public enum ExecutorApprovalPolicy: String, Sendable {
    case full, ask, deny
    public static func resolve(runtime: AgentRuntimeKind, mode: String?, confirmed: Bool = true) -> Self {
        guard confirmed, let mode else { return .ask }
        switch (runtime, mode) {
        case (.defaultAgent, "full"), (.codex, "agent-full-access"),
             (.claudeCode, "bypassPermissions"), (.grokBuild, "bypassPermissions"),
             (.cursor, "auto"), (.opencode, "full"), (.opencode, "auto"), (.hermes, "full"),
             (.openclaw, "full"): return .full
        case (.claudeCode, "dontAsk"), (.claudeCode, "plan"), (.grokBuild, "dontAsk"),
             (.openclaw, "read-only"): return .deny
        // Codex's historical "read-only" wire preset is Woven's Ask for
        // approval choice. External calls still need the normal explicit review.
        default: return .ask
        }
    }
}
