import Foundation
import WovenProtocol

/// Defaults for new chats: saved per runtime, for every machine or one machine,
/// and captured once when a chat is created.
///
/// Each is the synced setting `agentDefaults.<runtime>` (every machine) or
/// `agentDefaults.<runtime>.<machineID>` (one machine), a JSON object with
/// `model`, `thinking`, `permission` and `tools`, any of them missing. A machine
/// with its own key uses it alone; one without follows the key for every machine.
extension SettingsStore {
    static func agentDefaultsKey(_ runtime: AgentRuntimeKind, machineID: String?) -> String {
        "agentDefaults.\(runtime.runtime.rawValue)" + (machineID.map { ".\($0)" } ?? "")
    }

    /// `machineID` nil reads the defaults for every machine.
    func agentSelectionDefaults(runtime: AgentRuntimeKind, machineID: String?) async throws -> AgentSelectionDefaults {
        let shared = selections(Self.agentDefaultsKey(runtime, machineID: nil)) ?? SessionSelections()
        guard let machineID else { return AgentSelectionDefaults(stored: shared, resolved: shared, usesShared: true) }
        guard let own = selections(Self.agentDefaultsKey(runtime, machineID: machineID)) else {
            return AgentSelectionDefaults(stored: SessionSelections(), resolved: shared, usesShared: true)
        }
        return AgentSelectionDefaults(stored: own, resolved: own, usesShared: false)
    }

    func saveAgentSelectionDefault(runtime: AgentRuntimeKind, machineID: String?, field: SessionSelectionField,
                                   selections: SessionSelections) async throws -> AgentSelectionDefaults {
        let key = Self.agentDefaultsKey(runtime, machineID: machineID)
        var value = self.selections(key) ?? SessionSelections()
        switch field {
        case .model:
            // A thinking level belongs to the model it was chosen for.
            if value.model != selections.model { value.thinking = nil }
            value.model = selections.model
        case .thinking: value.thinking = selections.thinking
        case .permission: value.permission = selections.permission
        case .tools: value.tools = selections.tools
        }
        try await set(key, to: Self.json(value, keepEmpty: machineID != nil))
        return try await agentSelectionDefaults(runtime: runtime, machineID: machineID)
    }

    /// Whether a machine follows the defaults for every machine. Keeping its own starts from those.
    func setAgentDefaultsSharing(runtime: AgentRuntimeKind, machineID: String, shared: Bool) async throws -> AgentSelectionDefaults {
        let key = Self.agentDefaultsKey(runtime, machineID: machineID)
        if shared {
            try await set(key, to: .null)
        } else {
            let common = selections(Self.agentDefaultsKey(runtime, machineID: nil)) ?? SessionSelections()
            try await set(key, to: Self.json(common, keepEmpty: true))
        }
        return try await agentSelectionDefaults(runtime: runtime, machineID: machineID)
    }

    /// The options a new chat with `runtime` on that machine can choose from: what the
    /// runtime last reported on this Mac. `model` is not used; the levels are the current model's.
    func sessionOptions(runtime: AgentRuntimeKind, machineID: String?, model: String?) async throws -> SessionSettings {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        if let machineID, machineID != server.remote?.machine.id { throw ClientError.notOffered("Another machine's options") }
        guard let configuration = try await server.call(GetRuntimeConfiguration(runtime: runtime.runtime)) else {
            throw RuntimeOptionsUnknown(runtime: runtime)
        }
        func metadata(_ options: [SessionOption]) -> [String: SessionOptionMetadata] {
            Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.name, description: $0.detail)) },
                       uniquingKeysWith: { first, _ in first })
        }
        return SessionSettings(
            model: configuration.model, thinking: configuration.thinking, permission: configuration.permission,
            modelOptions: configuration.models.map(\.id), thinkingLevels: configuration.thinkingLevels.map(\.id),
            permissionOptions: configuration.permissionModes.map(\.id),
            modelOptionMetadata: metadata(configuration.models),
            thinkingOptionMetadata: metadata(configuration.thinkingLevels),
            permissionOptionMetadata: metadata(configuration.permissionModes))
    }

    private func selections(_ key: String) -> SessionSelections? {
        guard case .object(let fields)? = values[key] else { return nil }
        func string(_ name: String) -> String? { if case .string(let value)? = fields[name] { value } else { nil } }
        var tools: [String]?
        if case .array(let items)? = fields["tools"] {
            tools = items.compactMap { if case .string(let value) = $0 { value } else { nil } }
        }
        return SessionSelections(model: string("model"), thinking: string("thinking"), permission: string("permission"), tools: tools)
    }

    /// An empty choice for every machine unsets the key; a machine keeps `{}` to keep its own.
    private static func json(_ value: SessionSelections, keepEmpty: Bool) -> WovenProtocol.JSONValue {
        var fields: [String: WovenProtocol.JSONValue] = [:]
        if let model = value.model { fields["model"] = .string(model) }
        if let thinking = value.thinking { fields["thinking"] = .string(thinking) }
        if let permission = value.permission { fields["permission"] = .string(permission) }
        if let tools = value.tools { fields["tools"] = .array(tools.map { .string($0) }) }
        return fields.isEmpty && !keepEmpty ? .null : .object(fields)
    }
}

/// The runtime has not reported its options on this Mac since its server started.
struct RuntimeOptionsUnknown: LocalizedError {
    let runtime: AgentRuntimeKind
    var errorDescription: String? { "Start a chat with \(runtime.displayName) on this Mac to see its options." }
}
