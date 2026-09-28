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
    public static func connect(url: String, key: String, replacing existing: LocalModelServer? = nil) async throws
        -> LocalModelServer
    {
        // Active SDK sessions retain their model's endpoint. Keep a server's
        // identity bound to that endpoint so a new host's key can never be used
        // by an older session still addressing the previous host.
        if let existing, url.trimmingCharacters(in: .whitespacesAndNewlines) != existing.url {
            throw DefaultAgentError.message("Add a new connection to use a different server URL.")
        }
        guard existing != nil || servers.count < maximumServers else {
            throw DefaultAgentError.message("You can connect up to 12 local model servers.")
        }
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
        guard !result.models.isEmpty else { throw DefaultAgentError.message("The server did not return any models.") }
        return try await saveConnection(url: result.url, models: result.models, key: key, replacing: existing)
    }
    @MainActor private static func saveConnection(url: String, models: [String], key: String, replacing existing: LocalModelServer?) async throws -> LocalModelServer {
        func validate() throws {
            if let existing {
                guard servers.contains(existing) else {
                    throw DefaultAgentError.message("This server connection changed or was removed. Open Connections and try again.")
                }
            } else if servers.count >= maximumServers {
                throw DefaultAgentError.message("You can connect up to 12 local model servers.")
            }
        }
        try Task.checkCancellation()
        try validate()
        var server = existing ?? LocalModelServer(url: url, models: models)
        server.url = url
        server.models = models
        server.verifiedAt = .now
        let serverID = server.id
        try await ProviderConnectionStore.shared.perform {
            try DefaultAgentSupport.saveKey(key, provider: serverID, notify: false)
        }
        // Public preferences commit together on MainActor, using fresh values.
        // An edit/removal while Keychain was busy must not resurrect an old server.
        try validate()
        var values = servers
        values.removeAll { $0.id == server.id }
        values.append(server)
        servers = values
        DefaultAgentSupport.updateSettings { settings in
            if !settings.global.providers.contains(server.id) { settings.global.providers.append(server.id) }
        }
        return server
    }
    @MainActor public static func remove(_ server: LocalModelServer) async throws {
        try await ProviderConnectionStore.shared.perform {
            try DefaultAgentSupport.saveKey("", provider: server.id, notify: false)
        }
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
