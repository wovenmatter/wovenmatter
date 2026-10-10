import AppKit
import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore

@MainActor @Observable
final class DefaultAgentSettingsModel {
    struct Model: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let provider: String
        let providerName: String
    }
    struct Provider: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let connected: Bool
        let state: String?
        let detail: String?
        let account: String?
    }
    struct SignInOutcome: Codable, Equatable {
        let provider: String
        let notice: String?
        let error: String?
    }
    struct Status: Decodable {
        let providers: [Provider]
        let models: [Model]
        let searchConfigured: Bool
    }
    private struct ResultContext {
        let keyScope: String
        let removingAccount: String?
        let reconnectingAccount: String?
        let provider: String?
        let catalogOnly: Bool
        let catalogConfiguration: DefaultAgentSettings?
        let catalogKey: String?
        let sdkRevision: UInt64
    }
    private var connectionChangesTask: Task<Void, Never>?
    private var configurationChangesTask: Task<Void, Never>?
    private var accountsTask: Task<Void, Never>?
    private var receivedResult = false
    private var outputTask: Task<Void, Never>?
    private var catalogOnly = false
    private var catalogRequestConfiguration: DefaultAgentSettings?
    private var catalogRequestKey: String?
    private var catalogRequestSDKRevision: UInt64 = 0
    private var sdkCatalogRevisions: [String: UInt64] = [:]
    private var metadataInvalidationTask: Task<Void, Never>?
    private var catalogCache: [String: (configuration: DefaultAgentSettings, models: [Model])] = [:]
    private struct EnabledMetadata: Codable, Equatable, Sendable {
        var configuration: DefaultAgentSettings
        var models: [Model]
        var defaultModel: String?
        var selectedDefault: String?
        var connectedProviders: Set<String>
    }
    /// Only compact per-scope display metadata is persisted, off the main actor.
    private actor EnabledMetadataStore {
        static let shared = EnabledMetadataStore()
        private let prefix = "wovenmatter.built-in.enabled-metadata.v2."
        private var revisions: [String: UInt64] = [:]
        func read(_ key: String) -> EnabledMetadata? {
            guard let data = UserDefaults.standard.data(forKey: prefix + key), data.count <= 131_072 else { return nil }
            return try? JSONDecoder().decode(EnabledMetadata.self, from: data)
        }
        func invalidate(runtime: String, keys knownKeys: Set<String>, revision: UInt64) {
            let persisted = UserDefaults.standard.stringArray(forKey: prefix + "index") ?? []
            let affected = Set(persisted).union(knownKeys).filter {
                DefaultAgentSettingsModel.catalogRuntime(for: $0) == runtime
            }
            for key in affected {
                revisions[key] = max(revisions[key] ?? 0, revision)
                UserDefaults.standard.removeObject(forKey: prefix + key)
            }
            UserDefaults.standard.set(persisted.filter { !affected.contains($0) }, forKey: prefix + "index")
        }
        func write(_ value: EnabledMetadata, key: String, revision: UInt64) {
            guard revision >= (revisions[key] ?? 0) else { return }
            revisions[key] = revision
            guard let data = try? JSONEncoder().encode(value), data.count <= 131_072 else { return }
            UserDefaults.standard.set(data, forKey: prefix + key)
            var keys = UserDefaults.standard.stringArray(forKey: prefix + "index") ?? []
            keys.removeAll { $0 == key }
            keys.append(key)
            while keys.count > 32 {
                let stale = keys.removeFirst()
                UserDefaults.standard.removeObject(forKey: prefix + stale)
                revisions.removeValue(forKey: stale)
            }
            UserDefaults.standard.set(keys, forKey: prefix + "index")
        }
    }
    private var enabledMetadata: [String: EnabledMetadata] = [:]
    private var loadedMetadataKeys = Set<String>()
    private var metadataWriteRevision: UInt64 = 0
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration = UUID()
    private var catalogRemote: RemoteWorkspaceConfiguration?
    var browsingProvider = ""
    private var forceCatalogRefresh = false
    private var requestedAllModels = false
    private var publishedCatalogKey: String?
    init() {
        guard LocalExecutionRole.current != .frontend else { return }
        connectionChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: DefaultAgentSupport.credentialsChanged) {
                guard let self else { return }
                self.reloadStoredConnectionState()
            }
        }
        configurationChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: DefaultAgentSupport.configurationChanged) {
                guard let self else { return }
                let previousKeyScope = self.keyScope
                self.settings = DefaultAgentSupport.settings
                self.localServers = LocalModelServerStore.servers
                if self.keyScope != previousKeyScope { self.loadAccounts() }
                self.publishCatalog()
            }
        }
    }
    func reloadStoredConnectionState() {
        guard backendRequest == nil, LocalExecutionRole.current != .frontend else { return }
        settings = DefaultAgentSupport.settings
        localServers = LocalModelServerStore.servers
        providers = []
        publishCatalog()
        loadAccounts()
    }
    let sdks = DefaultAgentSDKSettingsModel()
    var localServers: [LocalModelServer] = []
    var backendRequest: ((String, Data) async throws -> Data)?
    private var backendCommandTask: Task<Void, Never>?
    private var backendPollTask: Task<Void, Never>?
    private var backendGeneration = UUID()
    private(set) var catalogSnapshotGeneration = UUID()
    private var backendCatalogRefreshTask: Task<Void, Never>?
    private var backendCommandError: String?

    private func forward(_ command: BackendConnectionsCommand) -> Bool {
        guard let request = backendRequest else {
            if LocalExecutionRole.current == .frontend {
                error = "The background service is not connected."
                busy = false
                return true
            }
            return false
        }
        backendPollTask?.cancel()
        backendGeneration = UUID()
        backendCommandError = nil
        let requestID = backendGeneration
        let previous = backendCommandTask
        backendCommandTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let catalogGeneration = self.catalogSnapshotGeneration
                let result = try await request("connections.command", JSONEncoder().encode(command))
                guard self.backendGeneration == requestID, !Task.isCancelled else { return }
                self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: result),
                    expectedCatalogGeneration: catalogGeneration)
                self.pollBackendIfNeeded()
            } catch {
                guard self.backendGeneration == requestID else { return }
                self.backendCommandError = error.localizedDescription
                self.error = error.localizedDescription; self.busy = false
            }
        }
        return true
    }
    private func pollBackendIfNeeded() {
        guard busy, let request = backendRequest else { return }
        backendPollTask?.cancel()
        let requestID = backendGeneration
        backendPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    let catalogGeneration = self.catalogSnapshotGeneration
                    let data = try await request("connections.snapshot", Data())
                    try Task.checkCancellation()
                    guard self.backendGeneration == requestID else { return }
                    self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data),
                        expectedCatalogGeneration: catalogGeneration)
                    if !self.busy { return }
                } catch is CancellationError { return }
                catch {
                    guard let self, self.backendGeneration == requestID else { return }
                    self.error = error.localizedDescription; self.busy = false; return
                }
            }
        }
    }
    var backendSnapshotGeneration: UUID { backendGeneration }
    func applyBackendSnapshot(_ value: BackendConnectionsSnapshot, expectedGeneration: UUID? = nil,
                              expectedCatalogGeneration: UUID? = nil) {
        if let expectedGeneration, expectedGeneration != backendGeneration { return }
        localServers = value.localServers
        scope = value.scope; settings = value.settings; providers = value.providers
        // SDK replacement may finish while an earlier snapshot is in transit.
        // Preserve account/operation updates, but never restore its old inventory.
        if expectedCatalogGeneration == nil || expectedCatalogGeneration == catalogSnapshotGeneration {
            catalog = value.catalog
            catalogIncludesAllModels = value.catalogIncludesAllModels ?? false
            resolvedDefaultModelID = value.resolvedDefaultModelID
        }
        searchConfigured = value.searchConfigured; accounts = value.accounts
        cursorAccountStatus = value.cursorAccountStatus; signInProvider = value.signInProvider
        signInOutcome = value.signInOutcome
        busy = value.busy; error = value.error; notice = value.notice
        signInURL = value.signInURL; signInCode = value.signInCode; prompt = value.prompt; promptID = value.promptID
        promptOptions = value.promptOptions.map { ($0.id, $0.label) }
    }
    func reloadLocalServers() async throws {
        try await localServerCommand(.init(action: "localServers"))
    }
    func connectLocalServer(url: String, key: String, replacing server: LocalModelServer?) async throws {
        try await localServerCommand(.init(action: "connectServer", value: key, label: url, server: server))
    }
    func removeLocalServer(_ server: LocalModelServer) async throws {
        try await localServerCommand(.init(action: "removeServer", server: server))
    }
    private func localServerCommand(_ command: BackendConnectionsCommand) async throws {
        if backendRequest != nil {
            _ = forward(command)
            let requestID = backendGeneration
            let task = backendCommandTask
            await task?.value
            guard backendGeneration == requestID, !Task.isCancelled else { throw CancellationError() }
            if let backendCommandError { throw DefaultAgentError.message(backendCommandError) }
            return
        }
        guard LocalExecutionRole.current != .frontend else { throw BackendRPCError.remote("The background service is not connected.") }
        let runID = generation, catalogGeneration = catalogSnapshotGeneration
        let data = try await BackendConnectionsService.handle(method: "connections.command", payload: JSONEncoder().encode(command), model: self)
        guard generation == runID, !Task.isCancelled else { throw CancellationError() }
        applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data),
            expectedCatalogGeneration: catalogGeneration)
    }

    var scope = "global"
    var settings = DefaultAgentSupport.settings
    var catalog: [Model] = []
    var catalogIncludesAllModels = false
    var resolvedDefaultModelID: String?
    var providers: [Provider] = []
    var searchConfigured = false
    func connectionLabel(_ id: String) -> String {
        if let provider = providers.first(where: { $0.id == id }) {
            return provider.connected ? "Credentials present" : "Connect account"
        }
        guard let saved = accounts[id] else { return "Status unchecked" }
        return saved.isEmpty ? "Connect account" : "Credential saved · status unchecked"
    }
    private func invalidateConnection(_ provider: String) {
        providers.removeAll { $0.id == provider }
    }
    var cursorAccountStatus = "Refresh to check Cursor sign-in"
    var signInProvider: String?
    var signInOutcome: SignInOutcome?
    var accounts: [String: [ProviderConnectionAccounts.Account]] = [:]
    var busy = false
    var error: String?
    var notice: String?
    var signInURL: URL?
    var signInCode: String?
    var prompt: String?
    var promptID: String?
    var promptOptions: [(id: String, label: String)] = []
    private var process: Process?
    private var input: FileHandle?
    private let inputQueue = DispatchQueue(label: "wovenmatter.built-in.settings-input", qos: .userInitiated)
    private var outputBuffer = Data()
    private var generation = UUID()
    private var operationTask: Task<Void, Never>?
    private var signInLease: UUID?
    private var activeKeyScope = "global"
    private var removingAccount: String?
    private var reconnectingAccount: String?
    private var activeRemote: RemoteWorkspaceConfiguration?

    var configuration: DefaultAgentSettings {
        get { scope == "global" ? settings.global : settings.resolved(scope) }
        set {
            let base = configuration
            if base.defaultModel != newValue.defaultModel { resolvedDefaultModelID = nil }
            if backendRequest != nil || LocalExecutionRole.current == .frontend {
                if scope == "global" { settings.global = newValue } else { settings.workspaces[scope] = newValue }
                publishCatalog()
                _ = forward(.init(action: "configuration", configuration: newValue, configurationBase: base))
                return
            }
            applyConfiguration(newValue, base: base)
        }
    }
    func applyConfiguration(_ edited: DefaultAgentSettings, base: DefaultAgentSettings?) {
        let original = base ?? configuration
        if original.defaultModel != edited.defaultModel { resolvedDefaultModelID = nil }
        settings = DefaultAgentSupport.updateSettings { value in
            let current = scope == "global" ? value.global : value.resolved(scope)
            let merged = current.applyingChanges(from: original, to: edited)
            if scope == "global" { value.global = merged } else { value.workspaces[scope] = merged }
        }
        publishCatalog()
    }
    var inherits: Bool { scope != "global" && settings.workspaces[scope] == nil }
    var keyScope: String { inherits ? "global" : scope }
    var availableModelProviderIDs: Set<String> {
        var result = Set(accounts.filter { !$0.value.isEmpty }.map(\.key))
        for provider in providers {
            if provider.connected { result.insert(provider.id) }
            else { result.remove(provider.id) }
        }
        return result
    }
    var effectiveDefaultModel: String? {
        // A subset's first row is not the runtime's implicit default. Keep an
        // explicit saved choice, or the default resolved from a full result.
        if let resolvedDefaultModelID, isProviderEnabled(for: resolvedDefaultModelID) { return resolvedDefaultModelID }
        return configuration.defaultModel.flatMap { isProviderEnabled(for: $0) ? $0 : nil }
    }
    var orderedModels: [Model] {
        enabledModelIDs.compactMap { id in catalog.first { $0.id == id } }
    }
    private var enabledModelIDs: [String] {
        var seen = Set<String>()
        var ids = configuration.models.filter { isProviderEnabled(for: $0) && seen.insert($0).inserted }
        if let model = effectiveDefaultModel, seen.insert(model).inserted { ids.insert(model, at: 0) }
        return ids
    }
    private func isProviderEnabled(for model: String) -> Bool {
        let provider = String(model.split(separator: "/", maxSplits: 1).first ?? "")
        return configuration.providers.contains(provider)
    }
    func setInherits(_ value: Bool) {
        if forward(.init(action: "inherits", flag: value)) { return }
        settings = DefaultAgentSupport.updateSettings { settings in
            if value { settings.workspaces.removeValue(forKey: scope) }
            else { settings.workspaces[scope] = settings.global }
        }
        providers = []
        accounts = [:]
        publishCatalog()
        loadAccounts()
    }
    func saveKeyConfirmed(_ key: String, provider: String, label: String? = nil) async -> Bool {
        guard backendRequest != nil else {
            guard LocalExecutionRole.current != .frontend else {
                error = "The background service is not connected."
                return false
            }
            return await saveKey(key, provider: provider, label: label)
        }
        busy = true
        _ = forward(.init(action: "saveKey", provider: provider, value: key, label: label))
        let requestID = backendGeneration
        let task = backendCommandTask
        await task?.value
        return backendGeneration == requestID && error == nil && !Task.isCancelled
    }
    @discardableResult func saveKey(_ key: String, provider: String, label: String? = nil) async -> Bool {
        if forward(.init(action: "saveKey", provider: provider, value: key, label: label)) { return true }
        guard !inherits, !busy else { return false }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        signInProvider = nil
        do {
            _ = try await ProviderConnectionStore.shared.perform {
                try ProviderConnectionAccounts.addKey(
                    key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider, scope: accountScope, label: label)
            }
            guard generation == runID, !Task.isCancelled else { return false }
            notice = "Key saved."
            if ["anthropic", "xai-api"].contains(provider) { enableProvider(provider) }
            error = nil
            await loadAccountsAndWait()
            return generation == runID
        } catch {
            if generation == runID { self.error = error.localizedDescription }
            return false
        }
    }
    func loadAccounts(force: Bool = false) {
        if forward(.init(action: "accounts")) { return }
        accountsTask?.cancel()
        accountsTask = Task { [weak self] in await self?.loadAccountsAndWait(force: force) }
    }
    func loadAccountsAndWait(force: Bool = false) async {
        guard backendRequest == nil, LocalExecutionRole.current != .frontend else { return }
        let runID = generation, accountScope = keyScope
        do {
            let value = try await ProviderConnectionStore.shared.accounts(scope: accountScope, force: force)
            guard !Task.isCancelled, generation == runID, keyScope == accountScope,
                value.revision == DefaultAgentSupport.revision else { return }
            if accounts != value.accounts { accounts = value.accounts }
            publishCatalog()
            if !providers.contains(where: { $0.id == "exa" }) { searchConfigured = !(accounts["exa"] ?? []).isEmpty }
        } catch is CancellationError { }
        catch { if generation == runID, keyScope == accountScope { self.error = error.localizedDescription } }
    }
    func selectAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration? = nil) async {
        if forward(.init(action: "select", provider: provider, value: id, remote: remote)) { return }
        guard !inherits, !busy else { return }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        do {
            try await ProviderConnectionStore.shared.perform { try ProviderConnectionAccounts.select(id, provider: provider, scope: accountScope) }
            guard generation == runID, !Task.isCancelled else { return }
            invalidateConnection(provider)
            refresh(remote: remote)
        } catch { if generation == runID { self.error = error.localizedDescription } }
    }
    func moveAccount(_ id: String, provider: String, offset: Int) async {
        if forward(.init(action: "move", provider: provider, value: id, offset: offset)) { return }
        guard !inherits, !busy else { return }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        do {
            try await ProviderConnectionStore.shared.perform { try ProviderConnectionAccounts.move(id, offset: offset, provider: provider, scope: accountScope) }
            guard generation == runID, !Task.isCancelled else { return }
            await loadAccountsAndWait()
        } catch { if generation == runID { self.error = error.localizedDescription } }
    }
    func removeAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration? = nil) async {
        if forward(.init(action: "remove", provider: provider, value: id, remote: remote)) { return }
        guard !inherits, !busy else { return }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        do {
            if provider == "claude-subscription" {
                let profile = try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false) {
                    try ProviderConnectionAccounts.nativeProfile(id, provider: provider, scope: accountScope)
                }
                guard generation == runID, !Task.isCancelled else { return }
                refresh(remote: remote, login: provider, action: "logout", profile: profile, removingAccount: id)
            } else {
                try await ProviderConnectionStore.shared.perform { try ProviderConnectionAccounts.remove(id, provider: provider, scope: accountScope) }
                guard generation == runID, !Task.isCancelled else { return }
                invalidateConnection(provider)
                refresh(remote: remote)
            }
        } catch { if generation == runID { self.error = error.localizedDescription } }
    }
    func reconnectAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration?) async {
        if forward(.init(action: "reconnect", provider: provider, value: id, remote: remote)) { return }
        guard !inherits, !busy else { return }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        do {
            let profile = try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false) {
                provider == "claude-subscription" ? try ProviderConnectionAccounts.nativeProfile(id, provider: provider, scope: accountScope) : nil
            }
            guard generation == runID, !Task.isCancelled else { return }
            refresh(remote: remote, login: provider, profile: profile, reconnectingAccount: id)
        } catch { if generation == runID { self.error = error.localizedDescription } }
    }
    func signOut(_ provider: String, remote: RemoteWorkspaceConfiguration?) async {
        if forward(.init(action: "signOut", provider: provider, remote: remote)) { return }
        guard !inherits, !busy else { return }
        if provider == "claude-subscription" || remote != nil {
            refresh(remote: remote, login: provider, action: "logout")
            return
        }
        let runID = generation, accountScope = keyScope
        busy = true
        defer { if generation == runID { busy = false } }
        do {
            try await ProviderConnectionStore.shared.perform { try DefaultAgentSupport.saveKey("", provider: "oauth." + provider, scope: accountScope) }
            guard generation == runID, !Task.isCancelled else { return }
            refresh()
        } catch { if generation == runID { self.error = error.localizedDescription } }
    }
    private func enableProvider(_ id: String) {
        var config = configuration
        if !config.providers.contains(id) {
            config.providers.append(id)
            configuration = config
        }
    }
    func signInClaude(remote: RemoteWorkspaceConfiguration?) {
        if forward(.init(action: "claude", remote: remote)) { return }
        guard !inherits else { return }
        enableProvider("claude-subscription")
        refresh(remote: remote, login: "claude-subscription")
    }
    func refreshCursorStatus() async {
        if forward(.init(action: "cursorStatus")) { return }
        guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "cursor-agent")
            ?? LocalACPRuntimeResolver.resolveExecutable(named: "agent") else {
            cursorAccountStatus = "Cursor CLI is not installed"
            return
        }
        let status = await Task.detached { () -> String in
            let child = Process()
            child.executableURL = executable
            child.arguments = ["status", "--format", "json"]
            let output = Pipe()
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            child.standardInput = FileHandle.nullDevice
            do {
                try child.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if child.isRunning { child.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                guard child.terminationStatus == 0,
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Could not check Cursor sign-in" }
                guard value["isAuthenticated"] as? Bool == true else { return "Connect account" }
                let user = value["userInfo"] as? [String: Any]
                return user?["email"] as? String ?? "Credentials present"
            } catch { return "Could not check Cursor sign-in" }
        }.value
        cursorAccountStatus = status
    }
    func signInCursor() {
        if forward(.init(action: "cursorSignIn")) { return }
        cancel()
        signInProvider = "cursor"
        signInOutcome = nil
        error = nil
        notice = "Preparing Cursor sign-in…"
        guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "cursor-agent")
            ?? LocalACPRuntimeResolver.resolveExecutable(named: "agent") else {
            error = "Install Cursor’s agent CLI to connect this account."
            completeSignInPresentation()
            return
        }
        busy = true
        let runID = generation
        let child = Process()
        child.executableURL = executable
        child.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        environment["NO_OPEN_BROWSER"] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        child.standardInput = FileHandle.nullDevice
        outputBuffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == runID else { return }
                self.outputBuffer.append(data)
                if self.outputBuffer.count > 32768 { self.outputBuffer = self.outputBuffer.suffix(32768) }
                let text = String(decoding: self.outputBuffer, as: UTF8.self)
                let expression = try? NSRegularExpression(pattern: #"https://[^\s<>"\x1b]+"#)
                for match in expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                    guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                        let host = url.host, host == "cursor.com" || host.hasSuffix(".cursor.com") || host == "cursor.sh" || host.hasSuffix(".cursor.sh") else { continue }
                    self.signInURL = url
                    self.notice = "Open this link to complete Cursor sign-in."
                }
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.generation == runID else { return }
                self.notice = nil
                if child.terminationStatus == 0 {
                    await self.refreshCursorStatus()
                    guard self.generation == runID else { return }
                    self.notice = self.cursorAccountStatus
                } else { self.error = "Cursor sign-in did not complete. Try again." }
                self.completeSignInPresentation()
            }
        }
        do { try child.run(); process = child }
        catch { self.error = "Could not start Cursor sign-in."; completeSignInPresentation() }
    }
    func move(_ id: String, by offset: Int) {
        var value = configuration
        var order = orderedModels.map(\.id)
        guard let from = order.firstIndex(of: id), order.indices.contains(from + offset) else { return }
        order.swapAt(from, from + offset)
        value.models = order
        configuration = value
    }
    func setVisible(_ id: String, visible: Bool) {
        var value = configuration
        if visible {
            if !value.models.contains(id) { value.models.append(id) }
        } else {
            guard id != effectiveDefaultModel else { return }
            value.models.removeAll { $0 == id }
            value.fallbackModels.removeAll { $0 == id }
        }
        configuration = value
    }
    func moveFallback(_ id: String, by offset: Int) {
        var value = configuration
        guard let from = value.fallbackModels.firstIndex(of: id), value.fallbackModels.indices.contains(from + offset)
        else { return }
        value.fallbackModels.swapAt(from, from + offset)
        configuration = value
    }
    func setFallback(_ id: String, enabled: Bool) {
        var value = configuration
        value.fallbackModels.removeAll { $0 == id }
        if enabled { value.fallbackModels.append(id) }
        configuration = value
    }
    func changeScope(_ scope: String) {
        metadataTask?.cancel()
        metadataGeneration = UUID()
        requestedAllModels = false
        // The scope command has its own backend snapshot. Do not serialize the
        // previous full inventory before the enabled-only request follows it.
        catalog = []
        catalogIncludesAllModels = false
        resolvedDefaultModelID = nil
        publishedCatalogKey = nil
        catalogRemote = nil
        if backendRequest != nil {
            if self.scope != scope { catalog = []; providers = []; accounts = [:] }
            self.scope = scope
            _ = forward(.init(action: "scope", value: scope))
            return
        }
        let changedScope = self.scope != scope
        cancel()
        settings = DefaultAgentSupport.settings
        localServers = LocalModelServerStore.servers
        self.scope = scope
        if changedScope { catalog = []; providers = []; accounts = [:] }
        signInOutcome = nil
        notice = nil
        error = nil
    }
    private func clearCatalogRequest() {
        catalogOnly = false
        catalogRequestConfiguration = nil
        catalogRequestKey = nil
    }
    func cancel() {
        if forward(.init(action: "cancel")) { return }
        generation = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        metadataGeneration = UUID()
        clearCatalogRequest()
        operationTask?.cancel()
        operationTask = nil
        accountsTask?.cancel()
        accountsTask = nil
        stopHelper()
        finishSignIn()
        busy = false
        signInProvider = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
        promptID = nil
        promptOptions = []
    }
    private func stopHelper() {
        outputTask?.cancel()
        outputTask = nil
        // The reader task owns closing stdout after its cancellable read ends.
        // Serialize stdin closure with writes, which must stay off MainActor.
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let input { inputQueue.async { try? input.close() } }
        input = nil
    }
    private func completeSignInPresentation() {
        if let provider = signInProvider {
            signInOutcome = .init(provider: provider, notice: error == nil ? notice : nil, error: error)
            notice = nil
            error = nil
        }
        busy = false
        signInProvider = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
        promptID = nil
        promptOptions = []
        finishSignIn()
    }
    private func finishSignIn() {
        if let signInLease { ProviderAccountCoordinator.shared.endSignIn(signInLease) }
        signInLease = nil
    }
    func respond(_ answer: String) {
        if forward(.init(action: "respond", value: answer)) { return }
        guard let id = promptID else { return }
        write(["answerTo": id, "answer": answer])
        promptID = nil
        prompt = nil
        promptOptions = []
    }
    private var catalogConfiguration: DefaultAgentSettings {
        var value = DefaultAgentSettings()
        value.providers = requestedAllModels ? [browsingProvider].filter { configuration.providers.contains($0) } : configuration.providers
        value.customServers = LocalModelServerStore.servers
        return value
    }
    /// Entry and ordinary preference changes use metadata only. Starting the
    /// helper is reserved for an explicit request to browse one provider.
    func loadCatalog(remote: RemoteWorkspaceConfiguration? = nil, includeAllModels: Bool = false, provider: String? = nil, force: Bool = false) {
        forceCatalogRefresh = force
        if let provider { browsingProvider = provider }
        if !configuration.providers.contains(browsingProvider) { browsingProvider = configuration.providers.first ?? "" }
        let hasOtherOperation = busy && !catalogOnly
        let cacheKey = catalogKey(remote: remote)
        if publishedCatalogKey != cacheKey {
            catalog = []
            resolvedDefaultModelID = nil
            catalogIncludesAllModels = false
        }
        catalogRemote = remote
        requestedAllModels = includeAllModels
        if !includeAllModels {
            if catalogOnly { cancel() }
            catalogIncludesAllModels = false
            publishCatalog()
        } else {
            busy = true
            error = nil
        }
        if forward(.init(action: "catalog", provider: browsingProvider, value: force ? "refresh" : nil, flag: includeAllModels, remote: remote)) { return }
        let config = catalogConfiguration
        if !includeAllModels {
            hydrateEnabledMetadata(remote: remote)
            loadAccounts()
            return
        }
        // Coalesce only a real, matching in-flight discovery request.
        if catalogOnly, error == nil, catalogRequestKey == cacheKey,
           catalogRequestConfiguration == config, activeRemote == remote { return }
        publishCatalog()
        // Browsing must not replace an in-progress connection/sign-in operation.
        // Its status result can supply the full catalog; otherwise Browse retries
        // once that operation has finished.
        if hasOtherOperation { return }
        refresh(remote: remote, action: "catalog")
        loadAccounts()
    }
    func refreshCatalog() { loadCatalog(remote: catalogRemote, includeAllModels: true, force: true) }
    func waitForEnabledMetadata() async {
        await metadataTask?.value
        await accountsTask?.value
    }
    /// Successful SDK replacement invalidates every scope using that runtime.
    /// Do not launch discovery or cancel unrelated account operations here.
    func invalidateSDKCatalog(scopeKey: String) {
        let runtime = scopeKey.lowercased()
        catalogSnapshotGeneration = UUID()
        sdkCatalogRevisions[runtime, default: 0] &+= 1
        let currentKey = catalogKey(remote: catalogRemote)
        let keys = Set(catalogCache.keys).union(enabledMetadata.keys).union(loadedMetadataKeys).union([currentKey])
        for key in keys where Self.catalogRuntime(for: key) == runtime {
            catalogCache.removeValue(forKey: key)
            enabledMetadata.removeValue(forKey: key)
            loadedMetadataKeys.remove(key)
        }
        if backendRequest == nil && LocalExecutionRole.current != .frontend {
            metadataWriteRevision &+= 1
            let revision = metadataWriteRevision
            let previous = metadataInvalidationTask
            metadataInvalidationTask = Task {
                await previous?.value
                await EnabledMetadataStore.shared.invalidate(runtime: runtime, keys: keys, revision: revision)
            }
        }
        // Re-read the backend projection after invalidation without issuing a
        // catalog command. This also covers a successful update in another scope.
        if let request = backendRequest {
            backendCatalogRefreshTask?.cancel()
            let requestID = backendGeneration, catalogGeneration = catalogSnapshotGeneration
            backendCatalogRefreshTask = Task { [weak self] in
                do {
                    let data = try await request("connections.snapshot", Data())
                    guard let self, !Task.isCancelled, self.backendGeneration == requestID,
                          self.catalogSnapshotGeneration == catalogGeneration else { return }
                    self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data),
                        expectedGeneration: requestID, expectedCatalogGeneration: catalogGeneration)
                    self.pollBackendIfNeeded()
                } catch { /* Cached labels remain optional; normal refresh can retry. */ }
            }
        }
        guard Self.catalogRuntime(for: currentKey) == runtime else { return }
        metadataTask?.cancel()
        metadataGeneration = UUID()
        resolvedDefaultModelID = nil
        catalogIncludesAllModels = false
        catalog = enabledModelIDs.map(fallbackModel)
        publishCatalog()
        if backendRequest == nil && LocalExecutionRole.current != .frontend,
           !busy && !requestedAllModels && runtime == "local" {
            hydrateEnabledMetadata(remote: nil)
        }
    }
    nonisolated private static func catalogRuntime(for key: String) -> String? {
        guard let data = Data(base64Encoded: key),
              let parts = try? JSONDecoder().decode([String].self, from: data), parts.count > 1 else { return nil }
        return parts[1].lowercased()
    }
    private func sdkRevision(for key: String?) -> UInt64 {
        key.flatMap { Self.catalogRuntime(for: $0) }.flatMap { sdkCatalogRevisions[$0] } ?? 0
    }
    private func catalogKey(remote: RemoteWorkspaceConfiguration?) -> String {
        let endpoint = remote.map { [$0.id.uuidString, $0.hostName, $0.userName ?? "", String($0.remotePort), $0.workspaceID] } ?? ["local"]
        return ((try? JSONEncoder().encode([scope] + endpoint)) ?? Data()).base64EncodedString()
    }
    private func fallbackModel(_ id: String) -> Model {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let provider = parts.first ?? id
        let name = parts.count > 1 ? parts[1] : id
        let providerName = ProviderConnectionID(rawValue: provider)?.name
            ?? localServers.first { $0.id == provider }?.name ?? provider
        return Model(id: id, name: name, provider: provider, providerName: providerName)
    }
    private func publishCatalog() {
        let key = catalogKey(remote: catalogRemote)
        let stored = enabledMetadata[key]
        let isFrontend = backendRequest != nil || LocalExecutionRole.current == .frontend
        let cachedFull = catalogCache[key].flatMap { $0.configuration == catalogConfiguration ? $0.models : nil }
        // Frontend snapshots already hold the exact projection. Preference edits
        // must not collapse an open full browser while waiting for the backend.
        let full = cachedFull ?? (isFrontend && catalogIncludesAllModels && publishedCatalogKey == key ? catalog : nil)
        if full != nil {
            resolvedDefaultModelID = configuration.defaultModel ?? stored?.defaultModel
        } else if stored?.configuration == catalogConfiguration,
                  stored?.selectedDefault == configuration.defaultModel,
                  stored?.connectedProviders == availableModelProviderIDs {
            resolvedDefaultModelID = stored?.defaultModel
        } else if !isFrontend || publishedCatalogKey != key { resolvedDefaultModelID = nil }
        var known = Dictionary((stored?.models ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if publishedCatalogKey == key {
            for model in catalog { known[model.id] = model }
        }
        for model in full ?? [] { known[model.id] = model }
        let enabled = enabledModelIDs.map { known[$0] ?? fallbackModel($0) }
        if requestedAllModels, let full {
            let fullIDs = Set(full.map(\.id))
            // A removed/renamed catalog entry must not erase a saved selection.
            catalog = full + enabled.filter { !fullIDs.contains($0.id) }
            catalogIncludesAllModels = true
        } else {
            catalog = enabled
            catalogIncludesAllModels = false
        }
        publishedCatalogKey = key
        guard !isFrontend else { return }
        // Do not replace observed default evidence with the temporary empty
        // account set seen before asynchronous account metadata has arrived.
        let sameEvidence = stored?.configuration == catalogConfiguration && stored?.selectedDefault == configuration.defaultModel
        var remembered = enabled
        if sameEvidence, resolvedDefaultModelID == nil, let defaultID = stored?.defaultModel,
           !remembered.contains(where: { $0.id == defaultID }), let model = stored?.models.first(where: { $0.id == defaultID }) {
            remembered.append(model)
        }
        let snapshot = EnabledMetadata(configuration: catalogConfiguration, models: Array(remembered.prefix(256)),
            defaultModel: resolvedDefaultModelID ?? (sameEvidence ? stored?.defaultModel : nil),
            selectedDefault: configuration.defaultModel,
            connectedProviders: resolvedDefaultModelID != nil || !sameEvidence ? availableModelProviderIDs : stored?.connectedProviders ?? [])
        guard full != nil || loadedMetadataKeys.contains(key) else { return }
        guard snapshot != stored else { return }
        enabledMetadata[key] = snapshot
        if enabledMetadata.count > 32 {
            for stale in enabledMetadata.keys.sorted() where stale != key {
                if enabledMetadata.count <= 32 { break }
                enabledMetadata.removeValue(forKey: stale)
                loadedMetadataKeys.remove(stale)
            }
        }
        metadataWriteRevision &+= 1
        let revision = metadataWriteRevision
        Task { await EnabledMetadataStore.shared.write(snapshot, key: key, revision: revision) }
    }
    private func hydrateEnabledMetadata(remote: RemoteWorkspaceConfiguration?) {
        metadataTask?.cancel()
        metadataGeneration = UUID()
        let requestID = metadataGeneration
        let key = catalogKey(remote: remote)
        metadataTask = Task { [weak self] in
            guard let self else { return }
            await self.metadataInvalidationTask?.value
            guard !Task.isCancelled, self.metadataGeneration == requestID else { return }
            if !self.loadedMetadataKeys.contains(key) {
                let stored = await EnabledMetadataStore.shared.read(key)
                guard !Task.isCancelled, self.metadataGeneration == requestID,
                      self.catalogKey(remote: self.catalogRemote) == key, !self.requestedAllModels else { return }
                if self.enabledMetadata[key] == nil, let stored {
                    self.enabledMetadata[key] = stored
                    let names = Dictionary(stored.models.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
                    self.applyEnabledNames(names)
                }
                self.loadedMetadataKeys.insert(key)
                self.publishCatalog()
            }
            // Resolve preserved default evidence before selecting IDs to hydrate.
            await self.accountsTask?.value
            guard !Task.isCancelled, self.metadataGeneration == requestID,
                  self.catalogKey(remote: self.catalogRemote) == key, !self.requestedAllModels else { return }
        }
    }
    private func applyEnabledNames(_ names: [String: String]) {
        func replacing(_ models: [Model]) -> [Model] {
            models.map { model in
                guard let name = names[model.id] else { return model }
                return Model(id: model.id, name: name, provider: model.provider, providerName: model.providerName)
            }
        }
        catalog = replacing(catalog)
        let key = catalogKey(remote: catalogRemote)
        if let cached = catalogCache[key] {
            catalogCache[key] = (cached.configuration, replacing(cached.models))
        }
    }
    func refresh(remote: RemoteWorkspaceConfiguration? = nil, login: String? = nil, action: String? = nil, profile: String? = nil, removingAccount: String? = nil, reconnectingAccount: String? = nil) {
        if forward(.init(action: "refresh", provider: login, value: action, remote: remote, profile: profile, removingAccount: removingAccount, reconnectingAccount: reconnectingAccount)) { return }
        guard login == nil || !inherits else { return }
        cancel()
        self.activeRemote = remote
        self.catalogRemote = remote
        self.removingAccount = removingAccount
        self.reconnectingAccount = reconnectingAccount
        busy = true
        signInProvider = login
        if login != nil { signInOutcome = nil }
        receivedResult = false
        catalogOnly = action == "catalog"
        catalogRequestConfiguration = catalogConfiguration
        catalogRequestKey = catalogKey(remote: remote)
        catalogRequestSDKRevision = sdkRevision(for: catalogRequestKey)
        if !catalogOnly {
            if login == nil { ProviderAccountCoordinator.shared.invalidate() }
            loadAccounts(force: login == nil)
        }
        notice = nil
        error = nil
        let runID = generation
        activeKeyScope = keyScope
        operationTask = Task { [self] in
            do {
                let prepared: DefaultAgentPayload
                if catalogOnly {
                    prepared = .init(config: catalogRequestConfiguration ?? configuration, credentials: [:], workspace: scope)
                } else {
                    prepared = try await ProviderAccountCoordinator.shared.prepare(scope)
                }
                if login != nil {
                    let lease = try await ProviderAccountCoordinator.shared.beginSignIn()
                    guard generation == runID, !Task.isCancelled else {
                        ProviderAccountCoordinator.shared.endSignIn(lease)
                        return
                    }
                    signInLease = lease
                }
                try Task.checkCancellation()
                guard generation == runID else { return }
                if !catalogOnly {
                    // Preparing credentials may suspend while preferences change;
                    // cache results against the payload actually sent to the helper.
                    var launched = DefaultAgentSettings()
                    launched.providers = prepared.config.providers
                    launched.customServers = prepared.config.customServers
                    catalogRequestConfiguration = launched
                }
                var body = try JSONSerialization.jsonObject(with: prepared.data()) as! [String: Any]
                if catalogOnly { body["force"] = forceCatalogRefresh }
                body["action"] = action ?? (login == nil ? "status" : "login")
                if let login {
                    body["provider"] = login
                    if login == "claude-subscription" {
                        body["profile"] = profile ?? (action == "logout"
                            ? prepared.credentials[login]?.accountId ?? "legacy"
                            : UUID().uuidString.lowercased())
                    }
                }
                let child = Process()
                if let remote {
                    let launch = try RemoteHarnessLaunchResolver.resolve(
                        configuration: remote, runtimeKind: .defaultAgent,
                        processWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser
                    ).launch
                    child.executableURL = launch.executableURL
                    child.arguments = launch.arguments.map {
                        $0.replacingOccurrences(of: "'--remote'", with: "'--control'")
                    }
                } else {
                    guard let launch = DefaultAgentSupport.resolution().launchConfiguration else {
                        throw DefaultAgentError.message("The bundled helper is unavailable. Rebuild Woven Matter.")
                    }
                    child.executableURL = URL(fileURLWithPath: "/bin/sh")
                    child.arguments =
                        ["-c", #"ulimit -c 0; exec "$@""#, "woven-default-agent", launch.executableURL.path]
                        + launch.arguments + ["--control"]
                }
                let stdin = Pipe()
                let stdout = Pipe()
                child.standardInput = stdin
                child.standardOutput = stdout
                child.standardError = FileHandle.nullDevice
                let reader = stdout.fileHandleForReading
                try child.run()
                process = child
                input = stdin.fileHandleForWriting
                // Drain complete lines before handling EOF. A terminal result
                // owns its credential commit independently of helper shutdown.
                outputTask = Task.detached(priority: .utility) { [weak self] in
                    defer { try? reader.close() }
                    // FileHandle.read(upToCount:) waits to fill its buffer on
                    // macOS pipes. Sign-in must deliver each line while the
                    // helper stays alive waiting for the user's response.
                    let lines = ACPLineCursor(handle: reader)
                    do {
                        while !Task.isCancelled, let line = try await lines.next() {
                            await MainActor.run { [weak self] in
                                guard let self, self.generation == runID else { return }
                                self.receiveLine(line)
                            }
                        }
                    } catch is CancellationError { return }
                    catch {
                        await MainActor.run { [weak self] in
                            guard let self, self.generation == runID else { return }
                            self.failHelper("Could not read the Pi Durable helper response. Try again.")
                        }
                        return
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == runID else { return }
                        self.failHelper("Pi Durable setup did not complete. Try again.")
                    }
                }
                write(body)
            } catch {
                guard generation == runID else { return }
                clearCatalogRequest()
                busy = false
                self.error = error.localizedDescription
                completeSignInPresentation()
            }
        }
    }
    private func failHelper(_ message: String) {
        // Late pipe failures or EOF cannot override an accepted result while
        // its account changes are still being saved.
        guard !receivedResult else { return }
        receivedResult = true
        stopHelper()
        clearCatalogRequest()
        error = message
        completeSignInPresentation()
    }
    private func write(_ value: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0a)
            guard let input else { throw DefaultAgentError.message("Pi Durable helper disconnected.") }
            let runID = generation
            let body = data
            inputQueue.async { [weak self] in
                do { try input.write(contentsOf: body) }
                catch {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == runID else { return }
                        self.failHelper("Pi Durable helper disconnected. Try again.")
                    }
                }
            }
        } catch { failHelper("Pi Durable helper disconnected. Try again.") }
    }
    private func receiveLine(_ line: Data) {
        guard !receivedResult, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let result = object["result"] as? [String: Any] {
            receivedResult = true
            let runID = generation
            let context = ResultContext(keyScope: activeKeyScope, removingAccount: removingAccount,
                reconnectingAccount: reconnectingAccount, provider: signInProvider, catalogOnly: catalogOnly,
                catalogConfiguration: catalogRequestConfiguration, catalogKey: catalogRequestKey,
                sdkRevision: catalogRequestSDKRevision)
            // Navigation may cancel presentation and transport, but an accepted
            // result must finish saving its credentials in the captured scope.
            Task { [self] in await receiveResult(result, runID: runID, context: context) }
            return
        }
        if let error = object["error"] as? String {
            failHelper(error)
            return
        }
        if let event = object["notification"] as? [String: Any] {
            if let url = (event["url"] ?? event["verificationUri"]) as? String, let value = URL(string: url),
                value.scheme == "https"
            {
                signInURL = value
            }
            if let code = event["userCode"] as? String { signInCode = code }
            notice = (event["message"] ?? event["instructions"]) as? String
        }
        if let value = object["prompt"] as? [String: Any] {
            promptID = object["id"] as? String
            prompt = value["message"] as? String
            promptOptions = (value["options"] as? [[String: String]] ?? []).compactMap { v in
                guard let id = v["id"], let label = v["label"] else { return nil }
                return (id, label)
            }
        }
    }
    private func receiveResult(_ result: [String: Any], runID: UUID, context: ResultContext) async {
        defer {
            if generation == runID, context.catalogOnly { clearCatalogRequest() }
        }
        let data = try? JSONSerialization.data(withJSONObject: result)
        if context.catalogOnly {
            guard generation == runID else { return }
            guard context.sdkRevision == sdkRevision(for: context.catalogKey) else {
                busy = false
                publishCatalog()
                return
            }
            struct Catalog: Decodable { let models: [Model] }
            if let data, let response = try? JSONDecoder().decode(Catalog.self, from: data) {
                if let requested = context.catalogConfiguration, let cacheKey = context.catalogKey {
                    catalogCache[cacheKey] = (requested, response.models)
                    if catalogConfiguration != requested {
                        // A replacement can be a cache hit, so finish the old
                        // request before asking for the current configuration.
                        clearCatalogRequest()
                        busy = false
                        loadCatalog(remote: activeRemote, includeAllModels: requestedAllModels)
                        return
                    }
                }
                publishCatalog()
            } else { error = "The model catalog could not be loaded. Try again." }
            busy = false
            return
        }
        let status = data.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
        let accountScope = context.keyScope
        let removeID = result["disconnected"] as? Bool == true ? context.removingAccount : nil
        let removeProvider = context.provider
        let profile = result["connected"] as? Bool == true ? result["nativeProfile"] as? String : nil
        let provider = result["provider"] as? String
        let label = result["account"] as? String
        let reconnectID = context.reconnectingAccount
        let legacy = status?.providers.first { $0.id == "claude-subscription" && $0.connected }
        do {
            let credential: DefaultAgentCredential?
            if let raw = result["credential"] {
                credential = try JSONDecoder().decode(DefaultAgentCredential.self, from: JSONSerialization.data(withJSONObject: raw))
            } else { credential = nil }
            let legacyLabel = legacy?.account
            let needsLegacyCheck = legacy != nil && profile == nil
            let changesCredentials = removeID != nil || profile != nil || credential != nil || needsLegacyCheck
            if changesCredentials {
                try await ProviderConnectionStore.shared.perform {
                    if let removeID, let removeProvider {
                        try ProviderConnectionAccounts.remove(removeID, provider: removeProvider, scope: accountScope)
                    }
                    if let profile, let provider {
                        _ = try ProviderConnectionAccounts.addNative(profile: profile, provider: provider, scope: accountScope, label: label)
                    }
                    if let credential, let provider {
                        if let reconnectID { try ProviderConnectionAccounts.replace(credential, accountID: reconnectID, provider: provider, scope: accountScope) }
                        else { _ = try ProviderConnectionAccounts.addOAuth(credential, provider: provider, scope: accountScope) }
                    }
                    if needsLegacyCheck, try ProviderConnectionAccounts.list(provider: "claude-subscription", scope: accountScope).isEmpty {
                        _ = try ProviderConnectionAccounts.addNative(profile: "legacy", provider: "claude-subscription", scope: accountScope, label: legacyLabel)
                    }
                }
            }
            guard generation == runID, !Task.isCancelled else { return }
            if profile != nil || credential != nil, let provider { invalidateConnection(provider) }
            // Local account mutations already publish one notification after committing.
            if !changesCredentials, result["reset"] as? Bool == true || result["disconnected"] as? Bool == true {
                DefaultAgentSupport.changed()
            }
            await loadAccountsAndWait()
        } catch is CancellationError { return }
        catch {
            guard generation == runID else { return }
            self.error = "Sign-in completed but could not be saved in Keychain. Try again."
        }
        guard generation == runID, !Task.isCancelled else { return }
        removingAccount = nil
        if let status {
            if let key = context.catalogKey, let requested = context.catalogConfiguration,
               context.sdkRevision == sdkRevision(for: key) {
                catalogCache[key] = (requested, status.models)
            }
            providers = status.providers
            publishCatalog()
            searchConfigured = status.searchConfigured
        }
        if result["connected"] as? Bool == false {
            error = result["detail"] as? String ?? "Sign-in did not complete. Try again."
        }
        if error != nil { notice = nil }
        else if result["reset"] as? Bool == true {
            notice = "Workspace credentials reset. Shared connections are available; sign in again for independent workspace accounts."
        } else if result["disconnected"] as? Bool == true {
            notice = "Workspace sign-in removed. Shared credentials will be used when available."
        } else if result["connected"] as? Bool == true {
            notice = "Connected. This account is shared with the features that use it."
        }
        let shouldRefresh = error == nil && (result["connected"] as? Bool == true || result["disconnected"] as? Bool == true)
        if shouldRefresh, let provider = signInProvider { invalidateConnection(provider) }
        completeSignInPresentation()
        if shouldRefresh {
            let remote = activeRemote
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.generation == runID, !self.busy else { return }
                self.refresh(remote: remote)
            }
        }
    }

}
