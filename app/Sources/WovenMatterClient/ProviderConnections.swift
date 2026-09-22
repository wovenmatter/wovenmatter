import Foundation

public enum ProviderConnectionID: String, CaseIterable, Identifiable, Sendable {
    case chatGPT = "openai-codex"
    case openAI = "openai"
    case grok = "xai"
    case xaiAPI = "xai-api"
    case claudeSubscription = "claude-subscription"
    case claudeAPI = "anthropic"
    case openRouter = "openrouter"
    case openCodeGo = "opencode-go"
    case exa
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT subscription"
        case .openAI: "OpenAI API key"
        case .grok: "Grok subscription"
        case .xaiAPI: "xAI API key"
        case .claudeSubscription: "Claude subscription"
        case .claudeAPI: "Claude API key"
        case .openRouter: "OpenRouter"
        case .openCodeGo: "OpenCode Go"
        case .exa: "Exa search"
        }
    }
    public var isSubscription: Bool { self == .chatGPT || self == .grok || self == .claudeSubscription }
}

extension DefaultAgentCredential {
    /// Claims are display hints only. Provider authorization and billing remain
    /// server decisions; never use this label as proof of entitlement.
    public var accountLabel: String? {
        if let displayName { return displayName }
        guard type == "oauth", let access else { return nil }
        let parts = access.split(separator: ".")
        guard parts.count == 3 else { return accountId }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return accountId }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return (claims["email"] as? String) ?? (profile?["email"] as? String)
            ?? (claims["name"] as? String) ?? accountId ?? (claims["sub"] as? String)
    }
}

extension ProviderAccountCoordinator {
    /// App-wide consumers always resolve global connections, independently of
    /// Built-in model enablement or a remote workspace's overrides.
    public func appCredentials() async throws -> [String: DefaultAgentCredential] {
        try await prepare("global").credentials
    }

    public func grokDictationCredential() async throws -> DefaultAgentCredential {
        guard let credential = try await appCredentials()[ProviderConnectionID.grok.rawValue],
            credential.type == "oauth", let token = credential.access, !token.isEmpty,
            (credential.expires ?? 0) > Date().timeIntervalSince1970 * 1000
        else {
            throw GrokSpeechError.signInRequired
        }
        return credential
    }
}

/// Account secrets and their ordering live together in Keychain. The canonical
/// slot remains compatible with Usage and Dictation, including OpenRouter's
/// existing shared key. Nothing here writes credentials to preferences or disk.
public enum ProviderConnectionAccounts {
    public static let limit = 4
    public struct Account: Identifiable, Codable, Equatable, Sendable {
        public let id: String
        public var label: String
        public let createdAt: Date?
        public var isSelected: Bool
    }
    private struct Entry: Codable {
        var account: Account
        var credential: DefaultAgentCredential
    }
    private struct Store: Codable {
        var entries: [Entry] = []
        var pendingPreviousEntries: [Entry]?
    }
    private static func isOAuth(_ provider: String) -> Bool { ["openai-codex", "xai", "claude-subscription", "cursor"].contains(provider) }
    private static func canonical(_ provider: String, scope: String, keychain: KeychainAccess) throws -> DefaultAgentCredential? {
        if isOAuth(provider) { return try DefaultAgentSupport.oauth(provider, scope: scope, keychain: keychain) }
        return try DefaultAgentSupport.key(provider, scope: scope, keychain: keychain).map { .init(type: "api_key", key: $0) }
    }
    private static func writeCanonical(_ value: DefaultAgentCredential?, provider: String, scope: String, keychain: KeychainAccess) throws {
        if isOAuth(provider) {
            if let value { try DefaultAgentSupport.saveOAuth(value, provider: provider, scope: scope, notify: false, keychain: keychain) }
            else { try DefaultAgentSupport.saveKey("", provider: "oauth." + provider, scope: scope, notify: false, keychain: keychain) }
        } else { try DefaultAgentSupport.saveKey(value?.key ?? "", provider: provider, scope: scope, notify: false, keychain: keychain) }
    }
    private static func persist(_ store: Store, provider: String, scope: String, keychain: KeychainAccess) throws {
        try DefaultAgentSupport.saveKey(String(decoding: JSONEncoder().encode(store), as: UTF8.self), provider: "accounts." + provider, scope: scope, notify: false, keychain: keychain)
    }
    private static func load(_ provider: String, scope: String, keychain: KeychainAccess) throws -> Store {
        let encoded = try DefaultAgentSupport.key("accounts." + provider, scope: scope, keychain: keychain)
        var store = try encoded.map { try JSONDecoder().decode(Store.self, from: Data($0.utf8)) } ?? Store()
        let current = try canonical(provider, scope: scope, keychain: keychain)
        if let previous = store.pendingPreviousEntries {
            let requested = store.entries.first { $0.account.isSelected }?.credential
            let before = previous.first { $0.account.isSelected }?.credential
            if current != requested && current == before { store.entries = previous }
            store.pendingPreviousEntries = nil
            try persist(store, provider: provider, scope: scope, keychain: keychain)
        }
        // Recover an interrupted selection without assigning the old secret to
        // the newly selected account's identity.
        if let current, let matching = store.entries.firstIndex(where: { $0.credential == current }),
            !store.entries[matching].account.isSelected {
            for index in store.entries.indices { store.entries[index].account.isSelected = index == matching }
        }
        if let index = store.entries.firstIndex(where: { $0.account.isSelected }) {
            if let current { store.entries[index].credential = current }
            else { store.entries.remove(at: index) }
        } else if let current {
            store.entries.insert(Entry(account: Account(id: UUID().uuidString.lowercased(), label: current.accountLabel ?? "Existing connection", createdAt: nil, isSelected: true), credential: current), at: 0)
        }
        // Save only the account index during migration; never replace the old
        // canonical key, so existing installations keep their working connection.
        if encoded == nil && !store.entries.isEmpty { try persist(store, provider: provider, scope: scope, keychain: keychain) }
        return store
    }
    public static func list(provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws -> [Account] {
        try DefaultAgentSupport.credentialLock.withLock { try load(provider, scope: scope, keychain: keychain).entries.map(\.account) }
    }
    public static func credential(_ id: String, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws -> DefaultAgentCredential? {
        try DefaultAgentSupport.credentialLock.withLock { try load(provider, scope: scope, keychain: keychain).entries.first { $0.account.id == id }?.credential }
    }
    private static func change(provider: String, scope: String, keychain: KeychainAccess, notify: Bool = true, _ body: (inout Store) throws -> Void) throws {
        try DefaultAgentSupport.credentialLock.withLock {
            var store = try load(provider, scope: scope, keychain: keychain)
            let old = store
            try body(&store)
            if !store.entries.isEmpty && !store.entries.contains(where: { $0.account.isSelected }) { store.entries[0].account.isSelected = true }
            // Persist backup first. A failed canonical write rolls back the index;
            // the previous canonical secret is never deleted before replacement.
            store.pendingPreviousEntries = old.entries
            try persist(store, provider: provider, scope: scope, keychain: keychain)
            do { try writeCanonical(store.entries.first { $0.account.isSelected }?.credential, provider: provider, scope: scope, keychain: keychain) }
            catch { try? persist(old, provider: provider, scope: scope, keychain: keychain); throw error }
            store.pendingPreviousEntries = nil
            try persist(store, provider: provider, scope: scope, keychain: keychain)
            if notify { DefaultAgentSupport.changed() }
        }
    }
    @discardableResult public static func addNative(profile: String, provider: String, scope: String = "global", label: String? = nil, keychain: KeychainAccess = .init()) throws -> Account {
        var value = DefaultAgentCredential(type: "native"); value.accountId = profile
        return try add(value, provider: provider, scope: scope, label: label ?? "Subscription", keychain: keychain)
    }
    public static func nativeProfile(_ id: String, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws -> String? {
        try credential(id, provider: provider, scope: scope, keychain: keychain)?.accountId
    }
    @discardableResult public static func addKey(_ key: String, provider: String, scope: String = "global", label: String? = nil, keychain: KeychainAccess = .init()) throws -> Account {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DefaultAgentError.message("Enter an API key.") }
        return try add(.init(type: "api_key", key: key), provider: provider, scope: scope, label: label, keychain: keychain)
    }
    @discardableResult public static func addOAuth(_ credential: DefaultAgentCredential, provider: String, scope: String = "global", label: String? = nil, keychain: KeychainAccess = .init()) throws -> Account {
        guard credential.type == "oauth", !credential.borrowed, credential.access?.isEmpty == false else { throw DefaultAgentError.message("This account did not return a valid sign-in credential.") }
        return try add(credential, provider: provider, scope: scope, label: label, keychain: keychain)
    }
    private static func add(_ credential: DefaultAgentCredential, provider: String, scope: String, label: String?, keychain: KeychainAccess) throws -> Account {
        var account = Account(id: UUID().uuidString.lowercased(), label: label ?? credential.accountLabel ?? "API key", createdAt: Date(), isSelected: false)
        try change(provider: provider, scope: scope, keychain: keychain) { store in
            if let index = store.entries.firstIndex(where: { $0.credential == credential || (credential.accountId != nil && $0.credential.accountId == credential.accountId) }) {
                store.entries[index].credential = credential
                if let label { store.entries[index].account.label = label }
                account = store.entries[index].account
                return
            }
            guard store.entries.count < limit else { throw DefaultAgentError.message("You can connect up to four accounts of each type.") }
            account.isSelected = store.entries.isEmpty
            if label == nil && credential.type == "api_key" { account.label = "API key \(store.entries.count + 1)" }
            store.entries.append(Entry(account: account, credential: credential))
        }
        return account
    }
    public static func replace(_ credential: DefaultAgentCredential, accountID: String, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws {
        try change(provider: provider, scope: scope, keychain: keychain) { store in
            guard let index = store.entries.firstIndex(where: { $0.account.id == accountID }) else { throw DefaultAgentError.message("This account is no longer connected.") }
            store.entries[index].credential = credential
            if let label = credential.accountLabel { store.entries[index].account.label = label }
        }
    }
    public static func select(_ id: String, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws {
        try change(provider: provider, scope: scope, keychain: keychain) { store in
            guard store.entries.contains(where: { $0.account.id == id }) else { throw DefaultAgentError.message("This account is no longer connected.") }
            for index in store.entries.indices { store.entries[index].account.isSelected = store.entries[index].account.id == id }
        }
    }
    public static func move(_ id: String, offset: Int, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws {
        try change(provider: provider, scope: scope, keychain: keychain) { store in
            store.entries = store.entries.filter { $0.account.isSelected } + store.entries.filter { !$0.account.isSelected }
            guard let index = store.entries.firstIndex(where: { $0.account.id == id }), !store.entries[index].account.isSelected else { return }
            let firstBackup = store.entries.contains { $0.account.isSelected } ? 1 : 0
            let target = max(firstBackup, min(store.entries.count - 1, index + offset))
            let entry = store.entries.remove(at: index); store.entries.insert(entry, at: target)
        }
    }
    public static func remove(_ id: String, provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws {
        try change(provider: provider, scope: scope, keychain: keychain) { $0.entries.removeAll { $0.account.id == id } }
    }
    public static func borrowedAccounts(provider: String, scope: String = "global", keychain: KeychainAccess = .init()) throws -> [DefaultAgentCredentialAccount] {
        try DefaultAgentSupport.credentialLock.withLock {
            let entries = try load(provider, scope: scope, keychain: keychain).entries
            let ordered = entries.filter { $0.account.isSelected } + entries.filter { !$0.account.isSelected }
            return ordered.map { .init(id: $0.account.id, label: $0.account.label, credential: $0.credential.type == "oauth" ? $0.credential.borrowing() : $0.credential) }
        }
    }
    @discardableResult public static func saveRenewed(_ value: DefaultAgentCredential, replacing original: DefaultAgentCredential, accountID: String, provider: String, scope: String, keychain: KeychainAccess = .init()) throws -> Bool {
        var saved = false
        try change(provider: provider, scope: scope, keychain: keychain, notify: false) { store in
            guard let index = store.entries.firstIndex(where: { $0.account.id == accountID }), store.entries[index].credential == original else { return }
            store.entries[index].credential = value; saved = true
        }
        return saved
    }
}
