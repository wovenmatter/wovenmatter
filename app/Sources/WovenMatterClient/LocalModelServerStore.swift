import Foundation
import WovenMatterCore

public enum LocalModelServerStore {
    public static let maximumServers = 12
    private static let storageKey = "wovenmatter.connections.local-servers.v1"
    /// Only public server addresses/catalogs are preferences. Keys use the same
    /// Keychain store and encrypted remote vault as other provider connections.
    public private(set) static var servers: [LocalModelServer] {
        get {
            UserDefaults.standard.data(forKey: storageKey).flatMap {
                try? JSONDecoder().decode([LocalModelServer].self, from: $0)
            } ?? []
        }
        set {
            guard newValue.count <= maximumServers, let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
            DefaultAgentSupport.changed()
        }
    }
    /// Connects a new server, or checks a saved one again (`replacing`). A saved
    /// server is the stored record with that ID and that URL, never the caller's
    /// copy, and its saved key (`key` empty) is only ever sent to its own URL.
    public static func connect(url: String, key: String?, replacing requested: LocalModelServer? = nil,
                               probe: ((String, String) async throws -> (url: String, models: [String]))? = nil) async throws
        -> LocalModelServer
    {
        let enteredKey = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let existing: LocalModelServer?
        if let requested {
            guard let stored = servers.first(where: { $0.id == requested.id && $0.url == requested.url }) else {
                throw DefaultAgentError.message("This server connection changed or was removed. Open Settings → Subscriptions & API Keys and try again.")
            }
            existing = stored
        } else { existing = nil }
        // Active SDK sessions retain their model's endpoint. Keep a server's
        // identity bound to that endpoint so a new host's key can never be used
        // by an older session still addressing the previous host.
        if let existing, url.trimmingCharacters(in: .whitespacesAndNewlines) != existing.url {
            throw DefaultAgentError.message("Add a new connection to use a different server URL.")
        }
        guard existing != nil || servers.count < maximumServers else {
            throw DefaultAgentError.message("You can connect up to 12 local model servers.")
        }
        let secret: String
        if !enteredKey.isEmpty { secret = enteredKey }
        else if let existing, let saved = try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false, {
            try DefaultAgentSupport.key(existing.id)
        }), !saved.isEmpty { secret = saved }
        else { throw DefaultAgentError.message("Enter the server API key.") }
        let checked = try await (probe ?? probeServer)(existing?.url ?? url, secret)
        guard !checked.models.isEmpty else { throw DefaultAgentError.message("The server did not return any models.") }
        if let existing, checked.url != existing.url {
            throw DefaultAgentError.message("Add a new connection to use a different server URL.")
        }
        return try await saveConnection(url: checked.url, models: checked.models, key: secret, replacing: existing)
    }
    private static func probeServer(_ url: String, _ key: String) async throws -> (url: String, models: [String]) {
        struct Request: Encodable {
            let action = "probe-server"
            let url: String
            let key: String
        }
        struct Result: Decodable {
            let url: String
            let models: [String]
            let error: String?
        }
        let data = try await DefaultAgentControl.run(JSONEncoder().encode(Request(url: url, key: key)))
        let result = try JSONDecoder().decode(Result.self, from: data)
        if let error = result.error { throw DefaultAgentError.message(error) }
        return (result.url, result.models)
    }
    private static func saveConnection(url: String, models: [String], key: String, replacing existing: LocalModelServer?) async throws -> LocalModelServer {
        // The actor owns the complete commit, not only its Keychain write. If
        // validation and preferences straddle an await, a concurrent reconnect
        // can pair one probe's model metadata with another probe's key, or leave
        // an unreferenced key when a new connection loses the capacity race.
        try await ProviderConnectionStore.shared.perform {
            var values = servers
            if let existing {
                guard values.contains(existing) else {
                    throw DefaultAgentError.message("This server connection changed or was removed. Open Settings → Subscriptions & API Keys and try again.")
                }
            } else if values.count >= maximumServers {
                throw DefaultAgentError.message("You can connect up to 12 local model servers.")
            }
            var server = existing ?? LocalModelServer(url: url, models: models)
            server.url = url
            server.models = models
            server.verifiedAt = .now
            try DefaultAgentSupport.saveKey(key, provider: server.id, notify: false)
            values.removeAll { $0.id == server.id }
            values.append(server)
            servers = values
            DefaultAgentSupport.updateSettings { settings in
                if !settings.global.providers.contains(server.id) { settings.global.providers.append(server.id) }
            }
            return server
        }
    }
    /// Removes a saved server and its own key: only a stored record with that ID
    /// and URL, never another Keychain item.
    @MainActor public static func remove(_ requested: LocalModelServer) async throws {
        try await ProviderConnectionStore.shared.perform {
            guard let server = servers.first(where: { $0.id == requested.id && $0.url == requested.url }) else {
                throw DefaultAgentError.message("This server connection changed or was removed. Open Settings → Subscriptions & API Keys and try again.")
            }
            try DefaultAgentSupport.saveKey("", provider: server.id, notify: false)
            servers.removeAll { $0.id == server.id }
            DefaultAgentSupport.updateSettings { settings in
                func clean(_ value: inout DefaultAgentSettings) {
                    value.providers.removeAll { $0 == server.id }
                    value.models.removeAll { $0.hasPrefix(server.id + "/") }
                    value.fallbackModels.removeAll { $0.hasPrefix(server.id + "/") }
                    if value.defaultModel?.hasPrefix(server.id + "/") == true { value.defaultModel = nil }
                }
                clean(&settings.global)
                for scope in settings.workspaces.keys { clean(&settings.workspaces[scope]!) }
            }
        }
    }
}
