import AppKit
import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore

@MainActor @Observable
final class DefaultAgentSettingsModel {
    struct Model: Codable, Equatable, Identifiable {
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
    }
    private var connectionChangesTask: Task<Void, Never>?
    private var configurationChangesTask: Task<Void, Never>?
    private var accountsTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var processingResult = false
    private var receivedResult = false
    private var outputEnded = false
    private var terminationStatus: Int32?
    private var outputTask: Task<Void, Never>?
    private var output: FileHandle?
    private var catalogOnly = false
    private var catalogRequestConfiguration: DefaultAgentSettings?
    private var catalogRequestKey: String?
    private var catalogCache: [String: (configuration: DefaultAgentSettings, models: [Model])] = [:]
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
            }
        }
    }
    func reloadStoredConnectionState() {
        guard backendRequest == nil, LocalExecutionRole.current != .frontend else { return }
        settings = DefaultAgentSupport.settings
        localServers = LocalModelServerStore.servers
        loadAccounts()
    }
    var localServers: [LocalModelServer] = []
    var backendRequest: ((String, Data) async throws -> Data)?
    private var backendCommandTask: Task<Void, Never>?
    private var backendPollTask: Task<Void, Never>?
    private var backendGeneration = UUID()

    private func forward(_ command: BackendConnectionsCommand) -> Bool {
        guard let request = backendRequest else {
            if LocalExecutionRole.current == .frontend {
                error = "The background service is not connected."
                return true
            }
            return false
        }
        backendPollTask?.cancel()
        backendGeneration = UUID()
        let requestID = backendGeneration
        let previous = backendCommandTask
        backendCommandTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await request("connections.command", JSONEncoder().encode(command))
                guard self.backendGeneration == requestID, !Task.isCancelled else { return }
                self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: result))
                self.pollBackendIfNeeded()
            } catch {
                guard self.backendGeneration == requestID else { return }
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
                    let data = try await request("connections.snapshot", Data())
                    try Task.checkCancellation()
                    guard let self, self.backendGeneration == requestID else { return }
                    self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data))
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
    func applyBackendSnapshot(_ value: BackendConnectionsSnapshot, expectedGeneration: UUID? = nil) {
        if let expectedGeneration, expectedGeneration != backendGeneration { return }
        localServers = value.localServers
        scope = value.scope; settings = value.settings; catalog = value.catalog; providers = value.providers
        searchConfigured = value.searchConfigured; accounts = value.accounts
        cursorAccountStatus = value.cursorAccountStatus; signInProvider = value.signInProvider
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
            if let error { throw DefaultAgentError.message(error) }
            return
        }
        guard LocalExecutionRole.current != .frontend else { throw BackendRPCError.remote("The background service is not connected.") }
        let runID = generation
        let data = try await BackendConnectionsService.handle(method: "connections.command", payload: JSONEncoder().encode(command), model: self)
        guard generation == runID, !Task.isCancelled else { throw CancellationError() }
        applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data))
    }

    var scope = "global"
    var settings = DefaultAgentSupport.settings
    var catalog: [Model] = []
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
            if backendRequest != nil || LocalExecutionRole.current == .frontend {
                if scope == "global" { settings.global = newValue } else { settings.workspaces[scope] = newValue }
                _ = forward(.init(action: "configuration", configuration: newValue))
                return
            }
            settings = DefaultAgentSupport.updateSettings { value in
                if scope == "global" { value.global = newValue } else { value.workspaces[scope] = newValue }
            }
        }
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
        let available = availableModelProviderIDs
        return configuration.defaultModel.flatMap { id in catalog.contains { $0.id == id } ? id : nil }
            ?? catalog.first { available.contains($0.provider) }?.id ?? catalog.first?.id
    }
    var orderedModels: [Model] {
        DefaultAgentModelCatalog.visibleIDs(explicit: configuration.models, defaultModel: effectiveDefaultModel, catalog: catalog.map(\.id)).compactMap { id in catalog.first { $0.id == id } }
    }
    func setInherits(_ value: Bool) {
        if forward(.init(action: "inherits", flag: value)) { return }
        settings = DefaultAgentSupport.updateSettings { settings in
            if value { settings.workspaces.removeValue(forKey: scope) }
            else { settings.workspaces[scope] = settings.global }
        }
        providers = []
        accounts = [:]
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
        error = nil
        notice = "Preparing Cursor sign-in…"
        guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "cursor-agent")
            ?? LocalACPRuntimeResolver.resolveExecutable(named: "agent") else {
            error = "Install Cursor’s agent CLI to connect this account."
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
                self.busy = false
                self.signInURL = nil
                if child.terminationStatus == 0 { await self.refreshCursorStatus(); self.notice = self.cursorAccountStatus }
                else { self.error = "Cursor sign-in did not complete. Try again." }
            }
        }
        do { try child.run(); process = child }
        catch { busy = false; self.error = "Could not start Cursor sign-in." }
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
        notice = nil
        error = nil
    }
    func cancel() {
        if forward(.init(action: "cancel")) { return }
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
        accountsTask?.cancel()
        accountsTask = nil
        // A received terminal result owns its credential commit. Navigation only
        // cancels presentation; a completed sign-in must remain connected.
        resultTask = nil
        processingResult = false
        outputTask?.cancel()
        outputTask = nil
        try? output?.close()
        output = nil
        finishSignIn()
        input?.closeFile()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        busy = false
        signInProvider = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
        promptID = nil
        promptOptions = []
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
        value.providers = configuration.providers
        value.customServers = LocalModelServerStore.servers
        return value
    }
    func loadCatalog(remote: RemoteWorkspaceConfiguration? = nil) {
        if forward(.init(action: "catalog", remote: remote)) { return }
        let config = catalogConfiguration
        let cacheKey = scope + ":" + (remote?.id.uuidString ?? "local")
        if let value = catalogCache[cacheKey], value.configuration == config {
            if catalog != value.models { catalog = value.models }
            loadAccounts()
            return
        }
        refresh(remote: remote, action: "catalog")
        loadAccounts()
    }
    func refresh(remote: RemoteWorkspaceConfiguration? = nil, login: String? = nil, action: String? = nil, profile: String? = nil, removingAccount: String? = nil, reconnectingAccount: String? = nil) {
        if forward(.init(action: "refresh", provider: login, value: action, remote: remote, profile: profile, removingAccount: removingAccount, reconnectingAccount: reconnectingAccount)) { return }
        guard login == nil || !inherits else { return }
        cancel()
        self.activeRemote = remote
        self.removingAccount = removingAccount
        self.reconnectingAccount = reconnectingAccount
        busy = true
        signInProvider = login
        receivedResult = false
        outputEnded = false
        terminationStatus = nil
        catalogOnly = action == "catalog"
        if catalogOnly {
            catalogRequestConfiguration = catalogConfiguration
            catalogRequestKey = scope + ":" + (remote?.id.uuidString ?? "local")
        } else {
            if login == nil { ProviderAccountCoordinator.shared.invalidate() }
            loadAccounts(force: login == nil)
        }
        notice = nil
        error = nil
        outputBuffer = Data()
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
                var body = try JSONSerialization.jsonObject(with: prepared.data()) as! [String: Any]
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
                child.terminationHandler = { [weak self] child in
                    Task { @MainActor in
                        guard let self, self.generation == runID else { return }
                        self.terminationStatus = child.terminationStatus
                        self.finishHelperIfNeeded()
                    }
                }
                try child.run()
                process = child
                input = stdin.fileHandleForWriting
                output = reader
                // One reader delivers bytes and EOF in order; process exit alone
                // cannot finish a result whose Keychain commit is still pending.
                outputTask = Task.detached(priority: .utility) { [weak self] in
                    defer { try? reader.close() }
                    do {
                        while !Task.isCancelled, let data = try reader.read(upToCount: 65_536), !data.isEmpty {
                            await MainActor.run { [weak self] in
                                guard let self, self.generation == runID else { return }
                                self.receive(data)
                            }
                        }
                    } catch { }
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == runID else { return }
                        self.outputEnded = true
                        self.finishHelperIfNeeded()
                    }
                }
                write(body)
            } catch {
                guard generation == runID else { return }
                busy = false
                self.error = error.localizedDescription
                finishSignIn()
            }
        }
    }
    private func finishHelperIfNeeded() {
        guard outputEnded, terminationStatus != nil, !processingResult, !receivedResult else { return }
        if error == nil { error = "Built-in setup did not complete. Try again." }
        busy = false
        finishSignIn()
    }
    private func write(_ value: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0a)
            try input?.write(contentsOf: data)
        } catch { self.error = "Built-in helper disconnected." }
    }
    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !receivedResult, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let result = object["result"] as? [String: Any] {
                guard !processingResult else { continue }
                processingResult = true
                receivedResult = true
                let runID = generation
                let context = ResultContext(keyScope: activeKeyScope, removingAccount: removingAccount,
                    reconnectingAccount: reconnectingAccount, provider: signInProvider, catalogOnly: catalogOnly,
                    catalogConfiguration: catalogRequestConfiguration, catalogKey: catalogRequestKey)
                resultTask = Task { [self] in await receiveResult(result, runID: runID, context: context) }
                continue
            }
            if let error = object["error"] as? String {
                receivedResult = true
                self.error = error
                busy = false
                finishSignIn()
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
    }
    private func receiveResult(_ result: [String: Any], runID: UUID, context: ResultContext) async {
        defer { if generation == runID { processingResult = false; finishHelperIfNeeded() } }
        let data = try? JSONSerialization.data(withJSONObject: result)
        if context.catalogOnly {
            guard generation == runID else { return }
            struct Catalog: Decodable { let models: [Model] }
            if let data, let response = try? JSONDecoder().decode(Catalog.self, from: data) {
                if let requested = context.catalogConfiguration, let cacheKey = context.catalogKey {
                    catalogCache[cacheKey] = (requested, response.models)
                    if catalogConfiguration != requested { loadCatalog(remote: activeRemote); return }
                }
                catalog = response.models
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
            error = "Sign-in completed but could not be saved in Keychain. Try again."
        }
        guard generation == runID, !Task.isCancelled else { return }
        removingAccount = nil
        finishSignIn()
        if let status {
            catalogCache.removeValue(forKey: scope + ":" + (activeRemote?.id.uuidString ?? "local"))
            providers = status.providers
            catalog = status.models
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
        busy = false
        signInProvider = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
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
