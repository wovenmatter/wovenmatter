import WovenMatterCompanion

public extension WorkspaceGoal {
    static func supports(_ runtime: AgentRuntimeKind?) -> Bool {
        guard let runtime else { return false }
        return [.defaultAgent, .codex, .claudeCode, .grokBuild, .opencode].contains(runtime)
    }
}
