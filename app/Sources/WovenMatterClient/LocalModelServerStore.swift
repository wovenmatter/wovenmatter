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
        return try await MainActor.run {
            try Task.checkCancellation()
            var values = servers
            if let existing {
                guard values.contains(existing) else {
                    throw DefaultAgentError.message(
                        "This server connection changed or was removed. Open Connections and try again.")
                }
            } else if values.count >= maximumServers {
                throw DefaultAgentError.message("You can connect up to 12 local model servers.")
            }
            var server = existing ?? LocalModelServer(url: result.url, models: result.models)
            server.url = result.url
            server.models = result.models
            server.verifiedAt = .now
            // Commit only after verification; a failed replacement keeps the saved connection.
            try DefaultAgentSupport.saveKey(key, provider: server.id, notify: false)
            values.removeAll { $0.id == server.id }
            values.append(server)
            servers = values
            var settings = DefaultAgentSupport.settings
            if !settings.global.providers.contains(server.id) { settings.global.providers.append(server.id) }
            DefaultAgentSupport.settings = settings
            return server
        }
    }
    @MainActor public static func remove(_ server: LocalModelServer) throws {
        try DefaultAgentSupport.saveKey("", provider: server.id)
        servers.removeAll { $0.id == server.id }
        var settings = DefaultAgentSupport.settings
        func clean(_ value: inout DefaultAgentSettings) {
            value.providers.removeAll { $0 == server.id }
            value.models.removeAll { $0.hasPrefix(server.id + "/") }
            value.fallbackModels.removeAll { $0.hasPrefix(server.id + "/") }
            if value.defaultModel?.hasPrefix(server.id + "/") == true { value.defaultModel = nil }
        }
        clean(&settings.global)
        for scope in settings.workspaces.keys { clean(&settings.workspaces[scope]!) }
        DefaultAgentSupport.settings = settings
    }
}
