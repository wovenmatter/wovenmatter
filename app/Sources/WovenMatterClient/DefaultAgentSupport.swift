import Foundation
import Security
import WovenMatterCore

public enum DefaultAgentSupport {
    public static let settingsKey = "wovenmatter.default-agent.settings.v1"
    public static var settings: DefaultAgentSettingsScope {
        get { UserDefaults.standard.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(DefaultAgentSettingsScope.self, from: $0) } ?? .init() }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: settingsKey) } }
    }
    public static var resources: URL? {
        let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath), URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()].compactMap { $0 }
        return roots.map { $0.appending(path: "default-agent") }.first { FileManager.default.fileExists(atPath: $0.appending(path: "src/main.mjs").path) }
    }
    public static func resolution() -> LocalACPRuntimeResolution {
        let root = resources
        let executable = root?.appending(path: "bin/node")
        let ready = executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        return LocalACPRuntimeResolution(availability: .init(runtimeKind: .defaultAgent, displayName: "Default Agent", state: ready ? .ready : .executableUnavailable,
            detail: ready ? "Built into Woven Matter. Configure connections in Settings → Default Agent." : "The bundled Default Agent helper is missing. Rebuild or reinstall Woven Matter.", executablePath: executable?.path),
            launchConfiguration: ready ? .init(runtimeKind: .defaultAgent, executableURL: executable!, arguments: [root!.appending(path: "src/main.mjs").path]) : nil)
    }
    public static func payload(workspace: String) throws -> Data {
        let scope = settings
        let config = scope.resolved(workspace)
        let keyScope = scope.workspaces[workspace] == nil ? "global" : workspace
        var credentials: [String: [String: Any]] = [:]
        for id in ["openai", "openrouter", "opencode-go", "exa"] {
            if let key = try key(id, scope: keyScope) ?? (keyScope == "global" ? nil : key(id, scope: "global")), !key.isEmpty { credentials[id] = ["type": "api_key", "key": key] }
        }
        if workspace != "local" { sharedOAuth().forEach { credentials[$0.key] = $0.value } }
        let configObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        return try JSONSerialization.data(withJSONObject: ["config": configObject, "credentials": credentials])
    }
    /// Share only short-lived access. The original sign-in retains refresh ownership.
    /// A remote workspace can establish its own OAuth session for independent renewal.
    private static func sharedOAuth() -> [String: [String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func object(_ path: URL) -> [String: Any] {
            guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
                  let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
        func expiry(_ token: String) -> Double {
            let pieces = token.split(separator: ".")
            guard pieces.count > 1 else { return 0 }
            var value = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.count % 4) % 4)
            guard let data = Data(base64Encoded: value), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = claims["exp"] as? Double else { return 0 }
            return exp * 1000
        }
        var result: [String: [String: Any]] = [:]
        let owned = object(home.appending(path: ".wovenmatter/default-agent/oauth.json"))
        for provider in ["openai-codex", "xai"] {
            if var value = owned[provider] as? [String: Any], value["type"] as? String == "oauth" {
                value["refresh"] = ""; value["borrowed"] = true; result[provider] = value
            }
        }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".codex")
        if result["openai-codex"] == nil, let tokens = object(codexHome.appending(path: "auth.json"))["tokens"] as? [String: Any], let access = tokens["access_token"] as? String {
            result["openai-codex"] = ["type": "oauth", "access": access, "refresh": "", "expires": expiry(access), "accountId": tokens["account_id"] as? String ?? "", "borrowed": true]
        }
        if result["xai"] == nil {
            let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".grok")
            for case let value as [String: Any] in object(grokHome.appending(path: "auth.json")).values {
                if let access = (value["access_token"] ?? value["accessToken"] ?? value["key"]) as? String {
                    result["xai"] = ["type": "oauth", "access": access, "refresh": "", "expires": expiry(access), "borrowed": true]; break
                }
            }
        }
        return result.filter { ($0.value["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 * 1000 + 300_000 }
    }

    public static func configuredLaunch(_ launch: LocalACPRuntimeLaunchConfiguration) throws -> LocalACPRuntimeLaunchConfiguration {
        var environment = launch.environment
        environment["WOVEN_DEFAULT_AGENT_CONFIGURATION"] = String(decoding: try payload(workspace: "local"), as: UTF8.self)
        return .init(runtimeKind: .defaultAgent, executableURL: launch.executableURL, arguments: launch.arguments,
            environment: environment, processWorkingDirectoryURL: launch.processWorkingDirectoryURL)
    }
    public static func key(_ provider: String, scope: String = "global") throws -> String? {
        let query = keyQuery(provider, scope: scope)
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DefaultAgentError.message("The provider key could not be read from Keychain (\(status)).") }
        return String(data: data, encoding: .utf8)
    }
    public static func saveKey(_ key: String, provider: String, scope: String = "global") throws {
        let query = keyQuery(provider, scope: scope)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DefaultAgentError.message("The provider key could not be removed (\(status)).") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DefaultAgentError.message("The provider key could not be saved in Keychain (\(status)).") }
    }
    private static func keyQuery(_ provider: String, scope: String) -> [String: Any] {
        // The global OpenRouter key is the same item already used by Usage.
        let shared = provider == "openrouter" && scope == "global"
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: WovenMatterKeychainService.current + (shared ? ".usage" : ".default-agent"),
                kSecAttrAccount as String: shared ? "openrouter.api-key" : "\(scope).\(provider)", kSecAttrSynchronizable as String: false]
    }
}
public enum DefaultAgentError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let message): message } }
}
