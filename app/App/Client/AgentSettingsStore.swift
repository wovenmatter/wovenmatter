import Foundation
import Observation
import WovenProtocol

/// Pi Durable's providers, models, accounts and fallbacks, and each machine's
/// subscriptions, API keys and local model servers.
///
/// Pi Durable's chat settings are the synced setting `piDurable` (every machine)
/// or `piDurable.<machineID>` (a machine that keeps its own); its default model is
/// the defaults for new chats' model. Sign-ins and keys go through this Mac's
/// server, which is the only one connected.
@MainActor
@Observable
final class AgentSettingsStore {
    struct SignInOption: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
    }

    // MARK: Pi Durable chat settings

    /// "global" for every machine, or a machine ID. The Pi Durable page shows this scope.
    private(set) var scope = "global"
    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var store: SettingsStore?

    func attach(_ server: ServerConnection, settings: SettingsStore) {
        self.server = server
        store = settings
    }

    /// Every machine's settings, as the synced settings hold them.
    var settings: PiDurableSettings {
        guard let values = store?.values else { return PiDurableSettings() }
        var result = PiDurableSettings()
        result.global = Self.decode(values[Self.key(nil)], defaultModel: values[SettingsStore.agentDefaultsKey(.defaultAgent, machineID: nil)])
        for (key, value) in values where key.hasPrefix(Self.key(nil) + ".") {
            let machineID = String(key.dropFirst(Self.key(nil).count + 1))
            guard case .object = value else { continue }
            result.machines[machineID] = Self.decode(value,
                defaultModel: values[SettingsStore.agentDefaultsKey(.defaultAgent, machineID: machineID)])
        }
        return result
    }

    /// The settings of `scope`. Setting it sends the change to the server.
    var configuration: DefaultAgentSettings {
        get { settings.resolved(scope) }
        set {
            guard newValue != configuration else { return }
            write(newValue, scope: scope)
        }
    }

    private static func key(_ machineID: String?) -> String { "piDurable" + (machineID.map { ".\($0)" } ?? "") }

    private func write(_ value: DefaultAgentSettings?, scope: String) {
        guard let store else { return error = ClientError.notConnected.localizedDescription }
        let key = Self.key(scope == "global" ? nil : scope)
        Task {
            do {
                try await store.set(key, to: value.map(Self.encode) ?? .null)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The default model is not stored here: it is the defaults for new chats' model.
    private static func encode(_ value: DefaultAgentSettings) -> WovenProtocol.JSONValue {
        .object([
            "providers": .array(value.providers.map { .string($0) }),
            "models": .array(value.models.map { .string($0) }),
            "fallbackModels": .array(value.fallbackModels.map { .string($0) }),
            "searchProvider": .string(value.searchProvider),
            "codeMode": .string(value.codeMode.rawValue),
            "subagentConcurrency": .integer(Int64(value.subagentConcurrency)),
        ])
    }

    private static func decode(_ value: WovenProtocol.JSONValue?, defaultModel: WovenProtocol.JSONValue?) -> DefaultAgentSettings {
        var result = DefaultAgentSettings()
        if case .object(let fields)? = defaultModel, case .string(let model)? = fields["model"] { result.defaultModel = model }
        guard case .object(let fields)? = value else { return result }
        func strings(_ name: String) -> [String]? {
            guard case .array(let items)? = fields[name] else { return nil }
            return items.compactMap { if case .string(let item) = $0 { item } else { nil } }
        }
        if let providers = strings("providers") { result.providers = providers }
        if let models = strings("models") { result.models = models }
        if let fallbacks = strings("fallbackModels") { result.fallbackModels = fallbacks }
        if case .string(let search)? = fields["searchProvider"] { result.searchProvider = search }
        if case .string(let mode)? = fields["codeMode"], let codeMode = BuiltInCodeMode(rawValue: mode) { result.codeMode = codeMode }
        if case .integer(let count)? = fields["subagentConcurrency"] { result.subagentConcurrency = Int(count) }
        return result
    }

    /// The machine in `scope` follows the settings for every machine.
    var inherits: Bool { scope != "global" && settings.machines[scope] == nil }

    // MARK: Catalog

    private(set) var catalog: [PiDurableModel] = []
    /// The catalog holds every provider model, not only the enabled ones.
    private(set) var catalogIncludesAllModels = false
    /// The provider whose models the catalog browser lists.
    var browsingProvider = ""
    /// The default model the server resolved for `scope`.
    private(set) var resolvedDefaultModelID: String?

    var effectiveDefaultModel: String? {
        if let resolvedDefaultModelID, isProviderEnabled(for: resolvedDefaultModelID) { return resolvedDefaultModelID }
        return configuration.defaultModel.flatMap { isProviderEnabled(for: $0) ? $0 : nil }
    }

    var orderedModels: [PiDurableModel] {
        var seen = Set<String>()
        var ids = configuration.models.filter { isProviderEnabled(for: $0) && seen.insert($0).inserted }
        if let model = effectiveDefaultModel, seen.insert(model).inserted { ids.insert(model, at: 0) }
        return ids.compactMap { id in catalog.first { $0.id == id } }
    }

    // MARK: Per-machine connections

    /// Machine ID → its accounts, provider states and local model servers.
    private(set) var machineConnections: [String: MachineProviderConnections] = [:]
    private(set) var sdkStates: [String: PiDurableSDKState] = [:]

    func connections(on machineID: String?) -> MachineProviderConnections {
        machineID.flatMap { machineConnections[$0] } ?? MachineProviderConnections()
    }

    func sdkState(on machineID: String) -> PiDurableSDKState { sdkStates[machineID] ?? PiDurableSDKState() }

    // MARK: Sign-in in progress

    private(set) var busy = false
    var error: String?
    private(set) var notice: String?
    /// The provider being signed in to, on `signInMachineID`.
    private(set) var signInProvider: String?
    private(set) var signInMachineID: String?
    private(set) var signInURL: URL?
    private(set) var signInCode: String?
    private(set) var prompt: String?
    private(set) var promptOptions: [SignInOption] = []
    private(set) var signInOutcome: ProviderSignInOutcome?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var flowID: String?
    @ObservationIgnored private var promptID: String?

    init() {}

    // MARK: Commands: Pi Durable settings

    func changeScope(_ scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        catalog = []
        catalogIncludesAllModels = false
        resolvedDefaultModelID = nil
        error = nil
        notice = nil
    }

    /// A machine that stops following the settings for every machine starts from them.
    func setInherits(_ value: Bool) {
        guard scope != "global", value != inherits else { return }
        write(value ? nil : settings.global, scope: scope)
    }

    /// The catalog is every model of the providers this Mac is connected to.
    func loadCatalog(includeAllModels: Bool, provider: String? = nil) {
        if let provider { browsingProvider = provider }
        Task { await readCatalog(refresh: false) }
    }

    func refreshCatalog() { Task { await readCatalog(refresh: true) } }

    private func readCatalog(refresh: Bool) async {
        guard let server, server.isConnected else { return error = ClientError.notConnected.localizedDescription }
        let requested = scope
        busy = true
        defer { busy = false }
        do {
            let models = try await server.call(ListProviderModels(refresh: refresh))
            guard scope == requested else { return }
            catalog = models.map { PiDurableModel(id: $0.id, name: $0.name, provider: $0.provider, providerName: $0.providerName) }
            catalogIncludesAllModels = true
            if browsingProvider.isEmpty || !catalog.contains(where: { $0.provider == browsingProvider }) {
                browsingProvider = catalog.first?.provider ?? ""
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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
            if value.defaultModel == nil { value.defaultModel = id }
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

    // MARK: Commands: accounts on a machine

    /// Reads Pi Durable's providers and whether each is connected there.
    func loadAccounts(on machineID: String?) {
        guard let machineID else { return }
        Task { await readAccounts(on: machineID) }
    }

    private func readAccounts(on machineID: String) async {
        guard let server = connectedServer(for: machineID) else { return }
        do {
            let list = try await server.call(ListSignIns())
            var connections = MachineProviderConnections()
            for signIn in list {
                connections.accounts[signIn.provider] = signIn.connected
                    ? [ProviderAccount(id: signIn.provider, label: signIn.name, createdAt: nil, isSelected: true)] : []
                connections.providers.append(ProviderStatus(id: signIn.provider, connected: signIn.connected))
            }
            machineConnections[machineID] = connections
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs a subscription's sign-in on that machine's server: its link and code show
    /// here, its questions are answered with `respond`.
    func signIn(_ provider: String, on machineID: String?) {
        guard let machineID, let server = connectedServer(for: machineID) else { return }
        cancel()
        signInProvider = provider
        signInMachineID = machineID
        signInOutcome = nil
        error = nil
        notice = nil
        busy = true
        var openings = 0
        signInTask = Task { [weak self] in
            await server.follow(StartSignIn(provider: provider), reply: { [weak self] flowID in
                openings += 1
                // A reconnect would start the sign-in again; it ends instead.
                guard openings == 1 else { self?.finishSignIn(provider, on: machineID, error: ClientError.notConnected.localizedDescription); return }
                self?.flowID = flowID
            }, event: { [weak self] event in
                self?.apply(event, provider: provider, on: machineID)
            }, failure: { [weak self] failure in
                self?.finishSignIn(provider, on: machineID, error: failure.localizedDescription)
            })
        }
    }

    private func apply(_ event: SignInEvent, provider: String, on machineID: String) {
        switch event {
        case .open(let url, let code, let instructions):
            if let link = URL(string: url) { signInURL = link }
            signInCode = code
            if let instructions { notice = instructions }
        case .prompt(let id, let message):
            promptID = id
            prompt = message
        case .finished:
            finishSignIn(provider, on: machineID, notice: "Connected.")
        case .failed(let message):
            finishSignIn(provider, on: machineID, error: message)
        }
    }

    private func finishSignIn(_ provider: String, on machineID: String, notice: String? = nil, error: String? = nil) {
        guard signInProvider == provider else { return }
        cancel()
        signInOutcome = ProviderSignInOutcome(provider: provider, notice: notice, error: error)
        Task { await readAccounts(on: machineID) }
    }

    /// Answers the sign-in's prompt: a code, a redirect URL or one of `promptOptions`.
    func respond(_ answer: String) {
        guard let server, let flowID, let promptID else { return }
        prompt = nil
        promptOptions = []
        self.promptID = nil
        Task {
            do { _ = try await server.call(AnswerSignIn(flowID: flowID, promptID: promptID, answer: answer)) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Stops a sign-in in progress; leaving the flow cancels it on the server.
    func cancel() {
        signInTask?.cancel()
        signInTask = nil
        flowID = nil
        promptID = nil
        signInProvider = nil
        signInMachineID = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
        promptOptions = []
        busy = false
    }

    /// Sets the provider's API key for every machine. True when the key was saved.
    func saveKey(_ key: String, provider: String, label: String?, on machineID: String?) async -> Bool {
        guard let server, server.isConnected else {
            error = ClientError.notConnected.localizedDescription
            return false
        }
        busy = true
        defer { busy = false }
        do {
            _ = try await server.call(SetAPIKey(provider: provider, key: key))
            error = nil
            if let machineID { await readAccounts(on: machineID) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Each provider keeps one sign-in or key, so there is no order to change.
    func selectAccount(_ id: String, provider: String, on machineID: String?) async {}

    func moveAccount(_ id: String, provider: String, offset: Int, on machineID: String?) async {}

    /// Signs a subscription out on that machine, or removes an API key from every machine.
    func removeAccount(_ id: String, provider: String, on machineID: String?) async {
        guard let machineID, let server = connectedServer(for: machineID) else { return }
        busy = true
        defer { busy = false }
        do {
            if ProviderConnectionID(rawValue: provider)?.isSubscription == true {
                _ = try await server.call(SignOut(provider: provider))
            } else {
                _ = try await server.call(SetAPIKey(provider: provider, key: nil))
            }
            error = nil
            signInOutcome = nil
            await readAccounts(on: machineID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reconnectAccount(_ id: String, provider: String, on machineID: String?) async {
        signIn(provider, on: machineID)
    }

    /// This Mac's server, when `machineID` is this Mac; otherwise says that machine is not connected.
    private func connectedServer(for machineID: String) -> ServerConnection? {
        guard let server, server.isConnected else {
            error = ClientError.notConnected.localizedDescription
            return nil
        }
        guard machineID == server.remote?.machine.id else {
            error = ClientError.notOffered("Another machine's sign-ins").localizedDescription
            return nil
        }
        return server
    }

    // MARK: Commands: local model servers

    /// The server keeps no local model servers yet, so there are none to list.
    func reloadLocalServers(on machineID: String?) async throws {}

    func connectLocalServer(url: String, key: String, replacing server: LocalModelServer?, on machineID: String?) async throws {
        throw ClientError.notOffered("Adding a model server")
    }

    func removeLocalServer(_ server: LocalModelServer, on machineID: String?) async throws {
        throw ClientError.notOffered("Removing a model server")
    }

    // MARK: Commands: Pi Durable SDK

    /// Reads, checks or updates Pi Durable's SDK on that machine. Updating installs the
    /// latest release for new sessions; running ones keep theirs.
    func requestSDK(_ action: PiDurableSDKAction, on machineID: String) {
        guard let server = connectedServer(for: machineID) else {
            sdkStates[machineID, default: PiDurableSDKState()].error = error
            return
        }
        guard sdkStates[machineID]?.busy != true else { return }
        sdkStates[machineID, default: PiDurableSDKState()].operation = action
        sdkStates[machineID]?.error = nil
        Task {
            do {
                if action == .update { _ = try await server.call(InstallRuntime(runtime: .piDurable)) }
                let status = try await server.call(ListRuntimes(checkForUpdates: true)).first { $0.runtime == .piDurable }
                sdkStates[machineID]?.status = status.map { status in
                    PiDurableSDKStatus(sdks: [.init(id: "pi", name: "Pi Durable SDK", installedVersion: status.version,
                                                    latestVersion: status.latestVersion, updateAvailable: status.updateAvailable,
                                                    notice: status.detail, consistent: nil)], notice: nil)
                }
            } catch {
                sdkStates[machineID]?.error = error.localizedDescription
            }
            sdkStates[machineID]?.operation = nil
        }
    }

    private func isProviderEnabled(for model: String) -> Bool {
        let provider = String(model.split(separator: "/", maxSplits: 1).first ?? "")
        return configuration.providers.contains(provider)
    }
}
