import Foundation
import Security
import WovenMatterCore

public enum DefaultAgentSupport {
    public static let lastEngineKey = "wovenmatter.built-in.last-engine"
    public static func sidebarName(engine: String) -> String {
        engine == "claude" ? "Built-in Claude SDK" : "Built-in Pi SDK"
    }
    public static let settingsKey = "wovenmatter.default-agent.settings.v1"
    public static var settings: DefaultAgentSettingsScope {
        get {
            UserDefaults.standard.data(forKey: settingsKey).flatMap {
                try? JSONDecoder().decode(DefaultAgentSettingsScope.self, from: $0)
            } ?? .init()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: settingsKey)
                changed()
            }
        }
    }
    public static var resources: URL? {
        let roots = [
            Bundle.main.resourceURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent(),
        ].compactMap { $0 }
        return roots.map { $0.appending(path: "default-agent") }.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "src/main.mjs").path)
        }
    }
    public static func resolution() -> LocalACPRuntimeResolution {
        let root = resources
        let executable = root?.appending(path: "bin/node")
        let ready = executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        return LocalACPRuntimeResolution(
            availability: .init(
                runtimeKind: .defaultAgent, displayName: "Built-in",
                state: ready ? .ready : .executableUnavailable,
                detail: ready
                    ? "Built into Woven Matter. Manage connections in Settings → Connections."
                    : "The bundled Built-in helper is missing. Rebuild or reinstall Woven Matter.",
                executablePath: executable?.path),
            launchConfiguration: ready
                ? .init(
                    runtimeKind: .defaultAgent, executableURL: executable!,
                    arguments: [root!.appending(path: "src/main.mjs").path]) : nil)
    }
    public static let credentialsChanged = Notification.Name("wovenmatter.default-agent.credentials-changed")
    private static let revisionLock = NSLock()
    private static let credentialLock = NSRecursiveLock()
    nonisolated(unsafe) private static var changeRevision: UInt64 = 0
    public static var revision: UInt64 { revisionLock.withLock { changeRevision } }
    public static func changed() {
        revisionLock.withLock { changeRevision &+= 1 }
        NotificationCenter.default.post(name: credentialsChanged, object: nil)
    }
    public static func snapshot(workspace: String) throws -> DefaultAgentPayload {
        let scope = settings
        let keyScope = workspace == "global" || scope.workspaces[workspace] == nil ? "global" : workspace
        var credentials: [String: DefaultAgentCredential] = [:]
        for id in ["openai", "openrouter", "opencode-go", "anthropic", "exa"] {
            if let key = try key(id, scope: keyScope) ?? (keyScope == "global" ? nil : key(id, scope: "global")),
                !key.isEmpty
            {
                credentials[id] = .init(type: "api_key", key: key)
            }
        }
        for server in LocalModelServerStore.servers {
            if let key = try key(server.id), !key.isEmpty { credentials[server.id] = .init(type: "api_key", key: key) }
        }
        for id in ["openai-codex", "xai"] {
            if let value = try oauth(id, scope: keyScope) ?? (keyScope == "global" ? nil : oauth(id)) {
                credentials[id] = value.borrowing()
            }
        }
        var config = workspace == "global" ? scope.global : scope.resolved(workspace)
        config.customServers = LocalModelServerStore.servers
        return DefaultAgentPayload(config: config, credentials: credentials, workspace: workspace)
    }
    public static func oauth(_ provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws
        -> DefaultAgentCredential?
    {
        guard let value = try key("oauth." + provider, scope: scope, keychain: keychain) else { return nil }
        return try JSONDecoder().decode(DefaultAgentCredential.self, from: Data(value.utf8))
    }
    public static func saveOAuth(
        _ credential: DefaultAgentCredential, provider: String, scope: String, notify: Bool = true,
        keychain: KeychainAccess = .init()
    ) throws {
        let value = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        try saveKey(value, provider: "oauth." + provider, scope: scope, notify: notify, keychain: keychain)
    }
    /// A sign-out or replacement account wins over a renewal already in flight.
    @discardableResult
    public static func saveRenewedOAuth(
        _ credential: DefaultAgentCredential, replacing original: DefaultAgentCredential,
        provider: String, scope: String, keychain: KeychainAccess = .init()
    ) throws -> Bool {
        try credentialLock.withLock {
            guard try oauth(provider, scope: scope, keychain: keychain) == original else { return false }
            try saveOAuth(credential, provider: provider, scope: scope, notify: false, keychain: keychain)
            return true
        }
    }
    public static func workspaceKey(_ workspace: String) throws -> String {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        if let existing = try key("encryption-key", scope: workspace) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DefaultAgentError.message("Could not generate the workspace encryption key.")
        }
        let value = Data(bytes).base64EncodedString()
        try saveKey(value, provider: "encryption-key", scope: workspace, notify: false)
        return value
    }
    public static func migrateLocalOAuth() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".wovenmatter/default-agent/oauth.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let values = try JSONDecoder().decode([String: DefaultAgentCredential].self, from: Data(contentsOf: path))
        for id in ["openai-codex", "xai"] {
            if let c = values[id], !c.borrowed, try oauth(id) == nil {
                try saveOAuth(c, provider: id, scope: "global", notify: false)
            }
        }
        // Delete only after every Keychain write has succeeded.
        try FileManager.default.removeItem(at: path)
    }

    public static func key(_ provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws
        -> String?
    {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        let query = keyQuery(provider, scope: scope)
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(readQuery)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DefaultAgentError.message("The provider key could not be read from Keychain (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }
    public static func hasKey(_ provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws
        -> Bool
    {
        var query = keyQuery(provider, scope: scope)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, _) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw DefaultAgentError.message("The connection could not be checked in Keychain (\(status)).")
        }
        return true
    }
    public static func saveKey(
        _ key: String, provider: String, scope: String = "global", notify: Bool = true,
        keychain: KeychainAccess = .init()
    ) throws {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        let query = keyQuery(provider, scope: scope)
        defer { if notify { changed() } }
        if key.isEmpty {
            let status = keychain.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DefaultAgentError.message("The provider key could not be removed (\(status)).")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = keychain.update(query, attributes)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = keychain.add(item)
        }
        guard status == errSecSuccess else {
            throw DefaultAgentError.message("The provider key could not be saved in Keychain (\(status)).")
        }
    }
    private static func keyQuery(_ provider: String, scope: String) -> [String: Any] {
        // The global OpenRouter key is the same item already used by Usage.
        let shared = provider == "openrouter" && scope == "global"
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: WovenMatterKeychainService.current + (shared ? ".usage" : ".default-agent"),
            kSecAttrAccount as String: shared ? "openrouter.api-key" : "\(scope).\(provider)",
            kSecAttrSynchronizable as String: false,
        ]
    }
}
public enum DefaultAgentError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
