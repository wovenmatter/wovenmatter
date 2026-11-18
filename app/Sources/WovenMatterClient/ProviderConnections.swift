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
    case brave
    case firecrawl
    public static let searchProviders: [Self] = [.exa, .brave, .firecrawl]
    public var isSearchProvider: Bool { Self.searchProviders.contains(self) }
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
        case .brave: "Brave Search"
        case .firecrawl: "Firecrawl"
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
    /// App-wide consumers (usage limits, bots) read this device's own sign-ins.
    public func appCredentials() async throws -> [String: DefaultAgentCredential] {
        try await prepare(ProviderConnectionAccounts.deviceScope).credentials
    }
}

/// Account secrets and their ordering live together in Keychain. The canonical
/// slot remains compatible with Usage, including OpenRouter's
/// existing shared key. Nothing here writes credentials to preferences or disk.
public enum ProviderConnectionAccounts {
    /// This device's sign-ins. Each device stores and renews its own; nothing is
    /// relayed. The Keychain names keep the historical `global` prefix, so the
    /// accounts that once were shared "All workspaces" accounts are this Mac's.
    public static let deviceScope = "global"
    public static let limit = 4
    public static func limit(for provider: String) -> Int {
        ProviderConnectionID(rawValue: provider)?.isSubscription == true ? 1 : limit
    }
    public struct Account: Identifiable, Codable, Equatable, Sendable {
        public let id: String
        public var label: String
        public let createdAt: Date?
        public var isSelected: Bool
        public init(id: String, label: String, createdAt: Date? = nil, isSelected: Bool) {
            self.id = id; self.label = label; self.createdAt = createdAt; self.isSelected = isSelected
        }
    }
    private struct Entry: Codable {
        var account: Account
        var credential: DefaultAgentCredential
    }
    private struct Store: Codable {
        var entries: [Entry] = []
        var pendingPreviousEntries: [Entry]?
        /// Set in the same write as the first device list the move to per-device
        /// sign-ins wrote (`migrateToDeviceSignIns`); from then on it only adds.
        var migrated: Bool?
    }
    private static func canonical(_ provider: String, scope: String, keychain: KeychainAccess) throws -> DefaultAgentCredential? {
        if ProviderConnectionID(rawValue: provider)?.isSubscription == true { return try DefaultAgentSupport.oauth(provider, scope: scope, keychain: keychain) }
        return try DefaultAgentSupport.key(provider, scope: scope, keychain: keychain).map { .init(type: "api_key", key: $0) }
    }
    private static func writeCanonical(_ value: DefaultAgentCredential?, provider: String, scope: String, keychain: KeychainAccess) throws {
        if ProviderConnectionID(rawValue: provider)?.isSubscription == true {
            if let value { try DefaultAgentSupport.saveOAuth(value, provider: provider, scope: scope, notify: false, keychain: keychain) }
            else { try DefaultAgentSupport.saveKey("", provider: "oauth." + provider, scope: scope, notify: false, keychain: keychain) }
        } else { try DefaultAgentSupport.saveKey(value?.key ?? "", provider: provider, scope: scope, notify: false, keychain: keychain) }
    }
    private static func persist(_ store: Store, provider: String, scope: String, keychain: KeychainAccess) throws {
        try DefaultAgentSupport.saveKey(String(decoding: JSONEncoder().encode(store), as: UTF8.self), provider: "accounts." + provider, scope: scope, notify: false, keychain: keychain)
    }
    /// Only real provider connections have accounts: a caller's provider string
    /// never reads or writes another Keychain item (`encryption-key`, `oauth.*`).
    private static func requireProvider(_ provider: String) throws {
        guard ProviderConnectionID(rawValue: provider) != nil else { throw DefaultAgentError.message("Choose a provider connection.") }
    }
    private static func load(_ provider: String, scope: String, keychain: KeychainAccess) throws -> Store {
        try requireProvider(provider)
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
        // Keep the canonical account; legacy backups must never become eligible
        // again after sign-out, a failed refresh, or a remote synchronization.
        if limit(for: provider) == 1 {
            let retained = current == nil ? [] : store.entries.filter { $0.account.isSelected }
            if retained.count != store.entries.count {
                store.entries = retained
                try persist(store, provider: provider, scope: scope, keychain: keychain)
            }
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
            guard store.entries.count < limit(for: provider) else {
                if limit(for: provider) == 1 { throw DefaultAgentError.message("Only one subscription account is supported. Reconnect or remove the current account first.") }
                throw DefaultAgentError.message("You can connect up to four accounts of each type.")
            }
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
    /// Where a sign-in the move to per-device sign-ins could not merge is kept,
    /// byte for byte, instead of being deleted.
    public static let preservedScope = "premigration"
    /// One-time move to per-device sign-ins. Before it, this Mac used its `local`
    /// accounts for each provider first and its `global` ones only where it had no
    /// local account. Now its accounts are one list (`deviceScope`).
    ///
    /// The first time it writes a provider's device list, the account this Mac used
    /// stays primary, its other local accounts follow, then the former `global`
    /// ones, up to the provider's limit; the device items as found are first copied
    /// to `preservedScope` (the baseline) and read back. Once that list has been
    /// written, or changed since (a sign-in or renewal on this device: it differs
    /// from the baseline, or an account was added after `since`, the first
    /// attempt), a later run never replaces or reorders it: it only adds local
    /// accounts still missing where there is room. Local items are removed only
    /// after a verified copy of them is kept (`preservedScope + ".local"`) and every
    /// local account is in the device list; otherwise they stay. Re-running changes
    /// nothing. Copies this Mac held for Linux hosts are not touched here.
    public static func migrateToDeviceSignIns(since: Date? = nil, keychain: KeychainAccess = .init()) throws {
        try DefaultAgentSupport.credentialLock.withLock {
            for provider in ProviderConnectionID.allCases.map(\.rawValue) {
                try migrateProvider(provider, since: since, keychain: keychain)
            }
        }
        DefaultAgentSupport.changed()
    }
    private static func sameAccount(_ a: DefaultAgentCredential, _ b: DefaultAgentCredential) -> Bool {
        a == b || (a.accountId != nil && a.accountId == b.accountId && a.type == b.type)
    }
    /// What can be told offline: a subscription with no refresh token whose access
    /// has expired, or borrowed access, can no longer sign in.
    private static func usable(_ credential: DefaultAgentCredential, now: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        guard credential.type == "oauth" else { return true }
        return !credential.borrowed && (!(credential.refresh ?? "").isEmpty || (credential.expires ?? 0) > now)
    }
    private static func items(_ provider: String) -> [String] { [provider, "oauth." + provider, "accounts." + provider] }
    private static func raw(_ provider: String, scope: String, keychain: KeychainAccess) throws -> [String?] {
        try items(provider).map { try DefaultAgentSupport.key($0, scope: scope, keychain: keychain) }
    }
    private static func migrateProvider(_ provider: String, since: Date?, keychain: KeychainAccess) throws {
        let device = deviceScope
        let localStore = try load(provider, scope: "local", keychain: keychain)
        let local = localStore.entries.filter { $0.account.isSelected } + localStore.entries.filter { !$0.account.isSelected }
        guard !local.isEmpty else { return }
        let deviceStore = try load(provider, scope: device, keychain: keychain)
        let existing = deviceStore.entries.filter { $0.account.isSelected } + deviceStore.entries.filter { !$0.account.isSelected }
        // The device items as the first attempt found them, kept once and never replaced.
        let baseline = try keepBaseline(provider, keychain: keychain)
        let current = try raw(provider, scope: device, keychain: keychain)
        let changedSince = baseline.map { $0 != current } ?? false
        let addedSince = since.map { since in existing.contains { ($0.account.createdAt ?? .distantPast) > since } } ?? false
        let firstWrite = deviceStore.migrated != true && !changedSince && !addedSince
        var target: [Entry]
        if firstWrite {
            // The same account in both scopes keeps the one that can still sign in
            // (the local one when both can, or when that cannot be told).
            var merged: [Entry] = []
            for entry in local + existing {
                if let index = merged.firstIndex(where: { sameAccount($0.credential, entry.credential) }) {
                    if !usable(merged[index].credential), usable(entry.credential) { merged[index].credential = entry.credential }
                } else { merged.append(entry) }
            }
            target = Array(merged.prefix(limit(for: provider))).enumerated().map { index, entry in
                var value = entry
                value.account.isSelected = index == 0
                return value
            }
        } else {
            // Only what is still missing, where there is room; nothing there moves.
            target = existing
            for entry in local where target.count < limit(for: provider) && !target.contains(where: { sameAccount($0.credential, entry.credential) }) {
                var value = entry
                value.account.isSelected = target.isEmpty
                target.append(value)
            }
        }
        let unchanged = target.map(\.credential) == existing.map(\.credential)
            && target.first?.account.id == existing.first?.account.id
        if !unchanged || deviceStore.migrated != true {
            try change(provider: provider, scope: device, keychain: keychain, notify: false) { store in
                store.entries = target
                store.migrated = true
            }
        }
        let stored = try load(provider, scope: device, keychain: keychain).entries
        guard stored.count == target.count, target.allSatisfy({ entry in stored.contains { $0.credential == entry.credential } }),
              stored.first(where: { $0.account.isSelected })?.credential == target.first?.credential else {
            throw DefaultAgentError.message("Sign-ins could not be verified after moving them.")
        }
        // Local items go once every local account is in the device list, and only
        // after a verified copy of them is kept. Otherwise they stay where they are.
        guard local.allSatisfy({ entry in stored.contains { sameAccount($0.credential, entry.credential) } }) else { return }
        if !local.allSatisfy({ entry in stored.contains { $0.credential == entry.credential } }) {
            guard try keepCopy(provider, from: "local", in: preservedScope + ".local", keychain: keychain) else { return }
        }
        for item in items(provider) {
            try DefaultAgentSupport.saveKey("", provider: item, scope: "local", notify: false, keychain: keychain)
        }
    }
    /// Copies the device items for one provider to `preservedScope` the first time,
    /// reading them back, and returns that first copy (`nil` before one exists).
    private static func keepBaseline(_ provider: String, keychain: KeychainAccess) throws -> [String?]? {
        let marker = "migrated." + provider
        if try DefaultAgentSupport.key(marker, scope: preservedScope, keychain: keychain) != nil {
            return try raw(provider, scope: preservedScope, keychain: keychain)
        }
        let current = try raw(provider, scope: deviceScope, keychain: keychain)
        try write(current, provider: provider, scope: preservedScope, keychain: keychain)
        try DefaultAgentSupport.saveKey(deviceScope, provider: marker, scope: preservedScope, notify: false, keychain: keychain)
        return current
    }
    /// Keeps a verified copy of a scope's items for one provider in `slot`, or in
    /// one of at most `extraCopies` further slots when the first holds other
    /// content. False when every slot is taken by other content: nothing is
    /// deleted then, and nothing blocks the migration.
    static let extraCopies = 3
    private static func keepCopy(_ provider: String, from scope: String, in slot: String, keychain: KeychainAccess) throws -> Bool {
        let current = try raw(provider, scope: scope, keychain: keychain)
        let marker = "migrated." + provider
        for index in 1...(1 + extraCopies) {
            let destination = index == 1 ? slot : slot + ".\(index)"
            if try DefaultAgentSupport.key(marker, scope: destination, keychain: keychain) != nil {
                if try raw(provider, scope: destination, keychain: keychain) == current { return true }
                continue
            }
            try write(current, provider: provider, scope: destination, keychain: keychain)
            try DefaultAgentSupport.saveKey(scope, provider: marker, scope: destination, notify: false, keychain: keychain)
            return true
        }
        return false
    }
    private static func write(_ values: [String?], provider: String, scope: String, keychain: KeychainAccess) throws {
        for (item, value) in zip(items(provider), values) {
            guard let value else { continue }
            try DefaultAgentSupport.saveKey(value, provider: item, scope: scope, notify: false, keychain: keychain)
            guard try DefaultAgentSupport.key(item, scope: scope, keychain: keychain) == value else {
                throw DefaultAgentError.message("Sign-ins could not be verified after moving them.")
            }
        }
    }
    /// Where what this Mac kept for a Linux workspace is moved once that host keeps
    /// its own vault: `premigration.<workspace>`.
    public static func preservedScope(forHost scope: String) -> String { preservedScope + "." + scope }
    /// What this Mac kept for a Linux workspace before per-device sign-ins (its
    /// accounts, subscriptions with their refresh tokens, and that host's vault key),
    /// once the host keeps its own vault. Nothing is deleted: each item is copied to
    /// `preservedScope(forHost:)`, read back, and only then removed from the
    /// workspace scope; an item whose copy differs stays where it is.
    public static func setAsideHostCopies(scope: String, keychain: KeychainAccess = .init()) throws {
        guard UUID(uuidString: scope) != nil else { return }
        let destination = preservedScope(forHost: scope)
        try DefaultAgentSupport.credentialLock.withLock {
            let items = ProviderConnectionID.allCases.flatMap { [$0.rawValue, "oauth." + $0.rawValue, "accounts." + $0.rawValue] } + ["encryption-key"]
            for item in items {
                guard let value = try DefaultAgentSupport.key(item, scope: scope, keychain: keychain) else { continue }
                let existing = try DefaultAgentSupport.key(item, scope: destination, keychain: keychain)
                if existing == nil { try DefaultAgentSupport.saveKey(value, provider: item, scope: destination, notify: false, keychain: keychain) }
                guard try DefaultAgentSupport.key(item, scope: destination, keychain: keychain) == value else { continue }
                try DefaultAgentSupport.saveKey("", provider: item, scope: scope, notify: false, keychain: keychain)
            }
        }
    }
    private static func deleteItems(provider: String, scope: String, keychain: KeychainAccess) throws {
        for item in [provider, "oauth." + provider, "accounts." + provider] {
            try DefaultAgentSupport.saveKey("", provider: item, scope: scope, notify: false, keychain: keychain)
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

/// Serial background owner for Settings account reads and writes. The cache holds
/// display metadata only; secrets remain in Keychain and the existing coordinator.
public actor ProviderConnectionStore {
    public static let shared = ProviderConnectionStore()
    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let accounts: [String: [ProviderConnectionAccounts.Account]]
    }
    public typealias Read = @Sendable (String) throws -> [String: [ProviderConnectionAccounts.Account]]
    private let read: Read
    private let version: @Sendable () -> UInt64
    private let clock: @Sendable () -> Date
    private var cached: [String: (snapshot: Snapshot, expires: Date)] = [:]
    public init(
        read: @escaping Read = ProviderConnectionStore.readStored,
        version: @escaping @Sendable () -> UInt64 = { DefaultAgentSupport.revision },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.read = read; self.version = version; self.clock = clock
    }
    public func accounts(scope: String, force: Bool = false) throws -> Snapshot {
        try Task.checkCancellation()
        if !force, let value = cached[scope], value.snapshot.revision == version(), clock() < value.expires {
            return value.snapshot
        }
        // A change concurrent with a Keychain read must never publish an old account list.
        while true {
            try Task.checkCancellation()
            let revision = version()
            let values = try read(scope)
            guard revision == version() else { continue }
            let result = Snapshot(revision: revision, accounts: values)
            cached[scope] = (result, clock().addingTimeInterval(300))
            return result
        }
    }
    public func perform<Value: Sendable>(invalidatesAccounts: Bool = true, _ operation: @Sendable () throws -> Value) throws -> Value {
        try Task.checkCancellation()
        defer { if invalidatesAccounts { cached.removeAll() } }
        return try operation()
    }
    nonisolated public static func readStored(_ scope: String) throws -> [String: [ProviderConnectionAccounts.Account]] {
        var values: [String: [ProviderConnectionAccounts.Account]] = [:]
        for provider in ProviderConnectionID.allCases.map(\.rawValue) {
            values[provider] = try ProviderConnectionAccounts.list(provider: provider, scope: scope)
        }
        return values
    }
}
