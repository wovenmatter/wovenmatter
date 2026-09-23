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
    private var connectionChangesTask: Task<Void, Never>?
    init() {
        guard LocalExecutionRole.current != .frontend else { return }
        connectionChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: DefaultAgentSupport.credentialsChanged) {
                guard let self else { return }
                self.reloadStoredConnectionState()
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

    private func forward(_ command: BackendConnectionsCommand) -> Bool {
        guard let request = backendRequest else {
            if LocalExecutionRole.current == .frontend {
                error = "The background service is not connected."
                return true
            }
            return false
        }
        backendPollTask?.cancel()
        let previous = backendCommandTask
        backendCommandTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await request("connections.command", JSONEncoder().encode(command))
                self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: result))
                self.pollBackendIfNeeded()
            } catch { self.error = error.localizedDescription; self.busy = false }
        }
        return true
    }
    private func pollBackendIfNeeded() {
        guard busy, let request = backendRequest else { return }
        backendPollTask?.cancel()
        backendPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let data = try await request("connections.snapshot", Data())
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data))
                    if !self.busy { return }
                } catch is CancellationError { return }
                catch { self?.error = error.localizedDescription; self?.busy = false; return }
            }
        }
    }
    func applyBackendSnapshot(_ value: BackendConnectionsSnapshot) {
        localServers = value.localServers
        scope = value.scope; settings = value.settings; catalog = value.catalog; providers = value.providers
        searchConfigured = value.searchConfigured; accountLabels = value.accountLabels; accounts = value.accounts
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
        let payload = try JSONEncoder().encode(command)
        let data: Data
        if let backendRequest {
            await backendCommandTask?.value
            data = try await backendRequest("connections.command", payload)
        } else {
            guard LocalExecutionRole.current != .frontend else { throw BackendRPCError.remote("The background service is not connected.") }
            data = try await BackendConnectionsService.handle(method: "connections.command", payload: payload, model: self)
        }
        applyBackendSnapshot(try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data))
    }
    var scope = "global"
    var settings = DefaultAgentSupport.settings
    var catalog: [Model] = []
    var providers: [Provider] = []
    var searchConfigured = false
    var accountLabels: [String: String] = [:]
    func connectionLabel(_ id: String) -> String {
        if let provider = providers.first(where: { $0.id == id }) {
            return provider.connected ? "Credentials present" : "Connect account"
        }
        return (accounts[id] ?? []).isEmpty ? "Connect account" : "Credential saved · status unchecked"
    }
    private func invalidateConnection(_ provider: String) {
        providers.removeAll { $0.id == provider }
        accountLabels[provider] = nil
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
            settings = DefaultAgentSupport.settings
            if scope == "global" { settings.global = newValue } else { settings.workspaces[scope] = newValue }
            DefaultAgentSupport.settings = settings
        }
    }
    var inherits: Bool { scope != "global" && settings.workspaces[scope] == nil }
    var keyScope: String { inherits ? "global" : scope }
    var effectiveDefaultModel: String? { configuration.defaultModel.flatMap { id in catalog.contains { $0.id == id } ? id : nil } ?? catalog.first { item in providers.contains { $0.id == item.provider && $0.connected } }?.id ?? catalog.first?.id }
    var orderedModels: [Model] {
        DefaultAgentModelCatalog.visibleIDs(explicit: configuration.models, defaultModel: effectiveDefaultModel, catalog: catalog.map(\.id)).compactMap { id in catalog.first { $0.id == id } }
    }
    func setInherits(_ value: Bool) {
        if forward(.init(action: "inherits", flag: value)) { return }
        settings = DefaultAgentSupport.settings
        if value {
            settings.workspaces.removeValue(forKey: scope)
        } else {
            settings.workspaces[scope] = settings.global
        }
        DefaultAgentSupport.settings = settings
    }
    func saveKeyConfirmed(_ key: String, provider: String, label: String? = nil) async -> Bool {
        guard backendRequest != nil else {
            guard LocalExecutionRole.current != .frontend else {
                error = "The background service is not connected."
                return false
            }
            return saveKey(key, provider: provider, label: label)
        }
        busy = true
        _ = forward(.init(action: "saveKey", provider: provider, value: key, label: label))
        await backendCommandTask?.value
        return error == nil
    }
    @discardableResult func saveKey(_ key: String, provider: String, label: String? = nil) -> Bool {
        if forward(.init(action: "saveKey", provider: provider, value: key, label: label)) { return true }
        guard !inherits else { return false }
        signInProvider = nil
        do {
            _ = try ProviderConnectionAccounts.addKey(
                key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider, scope: keyScope, label: label)
            notice = key.isEmpty ? "Key removed." : "Key saved."
            if ["anthropic", "xai-api"].contains(provider), !key.isEmpty { enableProvider(provider) }
            error = nil
            loadAccounts()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func loadAccounts() {
        if forward(.init(action: "accounts")) { return }
        for provider in ["openai-codex", "openai", "claude-subscription", "anthropic", "xai", "xai-api", "openrouter", "opencode-go", "exa", "cursor"] {
            do { accounts[provider] = try ProviderConnectionAccounts.list(provider: provider, scope: keyScope) }
            catch { self.error = error.localizedDescription }
        }
    }
    func selectAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration? = nil) {
        if forward(.init(action: "select", provider: provider, value: id, remote: remote)) { return }
        guard !inherits else { return }
        do { try ProviderConnectionAccounts.select(id, provider: provider, scope: keyScope); invalidateConnection(provider); refresh(remote: remote) }
        catch { self.error = error.localizedDescription }
    }
    func moveAccount(_ id: String, provider: String, offset: Int) {
        if forward(.init(action: "move", provider: provider, value: id, offset: offset)) { return }
        guard !inherits else { return }
        do { try ProviderConnectionAccounts.move(id, offset: offset, provider: provider, scope: keyScope); loadAccounts() }
        catch { self.error = error.localizedDescription }
    }
    func removeAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration? = nil) {
        if forward(.init(action: "remove", provider: provider, value: id, remote: remote)) { return }
        guard !inherits else { return }
        if provider == "claude-subscription" {
            do {
                let profile = try ProviderConnectionAccounts.nativeProfile(id, provider: provider, scope: keyScope)
                refresh(remote: remote, login: provider, action: "logout", profile: profile, removingAccount: id)
            } catch { self.error = error.localizedDescription }
            return
        }
        do { try ProviderConnectionAccounts.remove(id, provider: provider, scope: keyScope); invalidateConnection(provider); refresh(remote: remote) }
        catch { self.error = error.localizedDescription }
    }
    func reconnectAccount(_ id: String, provider: String, remote: RemoteWorkspaceConfiguration?) {
        if forward(.init(action: "reconnect", provider: provider, value: id, remote: remote)) { return }
        guard !inherits else { return }
        do {
            let profile = provider == "claude-subscription" ? try ProviderConnectionAccounts.nativeProfile(id, provider: provider, scope: keyScope) : nil
            refresh(remote: remote, login: provider, profile: profile, reconnectingAccount: id)
        } catch { self.error = error.localizedDescription }
    }
    func signOut(_ provider: String, remote: RemoteWorkspaceConfiguration?) {
        if forward(.init(action: "signOut", provider: provider, remote: remote)) { return }
        if provider == "claude-subscription" {
            refresh(remote: remote, login: provider, action: "logout")
            return
        }
        if let remote {
            refresh(remote: remote, login: provider, action: "logout")
            return
        }
        do {
            try DefaultAgentSupport.saveKey("", provider: "oauth." + provider, scope: keyScope)
            refresh()
        } catch { self.error = error.localizedDescription }
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
        if backendRequest != nil { self.scope = scope; _ = forward(.init(action: "scope", value: scope)); return }
        cancel()
        settings = DefaultAgentSupport.settings
        self.scope = scope
        catalog = []
        providers = []
        accountLabels = [:]
        notice = nil
        error = nil
    }
    func cancel() {
        if forward(.init(action: "cancel")) { return }
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
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
    func refresh(remote: RemoteWorkspaceConfiguration? = nil, login: String? = nil, action: String? = nil, profile: String? = nil, removingAccount: String? = nil, reconnectingAccount: String? = nil) {
        if forward(.init(action: "refresh", provider: login, value: action, remote: remote, profile: profile, removingAccount: removingAccount, reconnectingAccount: reconnectingAccount)) { return }
        guard login == nil || !inherits else { return }
        cancel()
        self.activeRemote = remote
        self.removingAccount = removingAccount
        self.reconnectingAccount = reconnectingAccount
        busy = true
        signInProvider = login
        loadAccounts()
        notice = nil
        error = nil
        outputBuffer = Data()
        let runID = generation
        activeKeyScope = keyScope
        operationTask = Task { [self] in
            do {
                let prepared = try await ProviderAccountCoordinator.shared.prepare(scope)
                accountLabels = prepared.credentials.compactMapValues { $0.accountLabel }
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
                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    Task { @MainActor in
                        guard self?.generation == runID else { return }
                        self?.receive(data)
                    }
                }
                child.terminationHandler = { [weak self] child in
                    Task { @MainActor in
                        guard let self, self.generation == runID else { return }
                        self.busy = false
                        if child.terminationStatus != 0 { self.finishSignIn() }
                        if child.terminationStatus != 0 && self.error == nil {
                            self.error = "Built-in setup did not complete. Try again."
                        }
                    }
                }
                try child.run()
                process = child
                input = stdin.fileHandleForWriting
                write(body)
            } catch {
                guard generation == runID else { return }
                busy = false
                self.error = error.localizedDescription
                finishSignIn()
            }
        }
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
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let result = object["result"] as? [String: Any] {
                if result["disconnected"] as? Bool == true, let id = removingAccount, let provider = signInProvider {
                    do { try ProviderConnectionAccounts.remove(id, provider: provider, scope: activeKeyScope) }
                    catch { self.error = error.localizedDescription }
                    removingAccount = nil
                }
                if result["connected"] as? Bool == true,
                    let profile = result["nativeProfile"] as? String, let provider = result["provider"] as? String {
                    do {
                        _ = try ProviderConnectionAccounts.addNative(profile: profile, provider: provider, scope: activeKeyScope, label: result["account"] as? String)
                        invalidateConnection(provider)
                    }
                    catch { self.error = error.localizedDescription }
                }
                if let raw = result["credential"], let provider = result["provider"] as? String {
                    do {
                        let credential = try JSONDecoder().decode(
                            DefaultAgentCredential.self, from: JSONSerialization.data(withJSONObject: raw))
                        if let id = reconnectingAccount {
                            try ProviderConnectionAccounts.replace(credential, accountID: id, provider: provider, scope: activeKeyScope)
                        } else {
                            _ = try ProviderConnectionAccounts.addOAuth(credential, provider: provider, scope: activeKeyScope)
                        }
                        invalidateConnection(provider)
                    } catch {
                        self.error = "Sign-in completed but could not be saved in Keychain. Try again."
                        busy = false
                        finishSignIn()
                        continue
                    }
                }
                loadAccounts()
                finishSignIn()
                if result["connected"] as? Bool == true {
                    notice = "Connected. This account is shared with the features that use it."
                }
                if result["credential"] != nil || result["connected"] != nil || result["reset"] != nil
                    || result["disconnected"] != nil
                {
                    DefaultAgentSupport.changed()
                }
                if let data = try? JSONSerialization.data(withJSONObject: result),
                    let status = try? JSONDecoder().decode(Status.self, from: data)
                {
                    if let legacy = status.providers.first(where: { $0.id == "claude-subscription" && $0.connected }),
                        (accounts["claude-subscription"] ?? []).isEmpty {
                        do { _ = try ProviderConnectionAccounts.addNative(profile: "legacy", provider: "claude-subscription", scope: activeKeyScope, label: legacy.account); loadAccounts() }
                        catch { self.error = error.localizedDescription }
                    }
                    providers = status.providers
                    catalog = status.models
                    searchConfigured = status.searchConfigured
                } else if result["reset"] as? Bool == true {
                    notice =
                        "Workspace credentials reset. Shared connections are available; sign in again for independent workspace accounts."
                } else if result["disconnected"] as? Bool == true {
                    notice = "Workspace sign-in removed. Shared credentials will be used when available."
                } else if result["connected"] as? Bool == true {
                    notice = "Connected. This account is shared with the features that use it."
                } else if result["connected"] as? Bool == false {
                    notice = nil
                    error = result["detail"] as? String ?? "Sign-in did not complete. Try again."
                }
                let shouldRefresh = result["connected"] as? Bool == true || result["disconnected"] as? Bool == true
                if shouldRefresh, let provider = signInProvider { invalidateConnection(provider) }
                busy = false
                signInProvider = nil
                signInURL = nil
                signInCode = nil
                prompt = nil
                if shouldRefresh, error == nil {
                    let completedGeneration = generation
                    let remote = activeRemote
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self, self.generation == completedGeneration, !self.busy else { return }
                        self.refresh(remote: remote)
                    }
                }
            }
            if let error = object["error"] as? String {
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
}
