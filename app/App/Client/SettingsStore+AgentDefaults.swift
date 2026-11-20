import Foundation

/// Defaults for new chats: saved per runtime, for every machine or one machine,
/// and captured once when a chat is created.
extension SettingsStore {
    /// `machineID` nil reads the defaults for every machine.
    func agentSelectionDefaults(runtime: AgentRuntimeKind, machineID: String?) async throws -> AgentSelectionDefaults {
        throw ClientError.notConnected
    }

    func saveAgentSelectionDefault(runtime: AgentRuntimeKind, machineID: String?, field: SessionSelectionField,
                                   selections: SessionSelections) async throws -> AgentSelectionDefaults {
        throw ClientError.notConnected
    }

    /// Whether a machine follows the defaults for every machine.
    func setAgentDefaultsSharing(runtime: AgentRuntimeKind, machineID: String, shared: Bool) async throws -> AgentSelectionDefaults {
        throw ClientError.notConnected
    }

    /// The options a new chat with `runtime` on that machine can choose from, for `model`.
    func sessionOptions(runtime: AgentRuntimeKind, machineID: String?, model: String?) async throws -> SessionSettings {
        throw ClientError.notConnected
    }
}
