import Foundation
import Observation

/// Pi Durable's providers, models, accounts and fallbacks, and each machine's
/// subscriptions, API keys and local model servers.
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
    private(set) var settings = PiDurableSettings()

    /// The settings of `scope`. Setting it sends the change to the server.
    var configuration: DefaultAgentSettings {
        get { settings.resolved(scope) }
        set {
            guard newValue != configuration else { return }
            error = ClientError.notConnected.localizedDescription
        }
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

    func setInherits(_ value: Bool) {
        guard scope != "global", value != inherits else { return }
        error = ClientError.notConnected.localizedDescription
    }

    func loadCatalog(includeAllModels: Bool, provider: String? = nil) {
        if let provider { browsingProvider = provider }
        if includeAllModels { error = ClientError.notConnected.localizedDescription }
    }

    func refreshCatalog() { loadCatalog(includeAllModels: true) }

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

    func loadAccounts(on machineID: String?) {}

    func signIn(_ provider: String, on machineID: String?) {
        signInOutcome = ProviderSignInOutcome(provider: provider, notice: nil,
                                              error: ClientError.notConnected.localizedDescription)
    }

    /// Answers the sign-in's prompt: a code, a redirect URL or one of `promptOptions`.
    func respond(_ answer: String) {}

    /// Stops a sign-in in progress.
    func cancel() {
        signInProvider = nil
        signInMachineID = nil
        signInURL = nil
        signInCode = nil
        prompt = nil
        promptOptions = []
        busy = false
    }

    /// True when the key was saved.
    func saveKey(_ key: String, provider: String, label: String?, on machineID: String?) async -> Bool {
        error = ClientError.notConnected.localizedDescription
        return false
    }

    func selectAccount(_ id: String, provider: String, on machineID: String?) async {
        error = ClientError.notConnected.localizedDescription
    }

    func moveAccount(_ id: String, provider: String, offset: Int, on machineID: String?) async {
        error = ClientError.notConnected.localizedDescription
    }

    func removeAccount(_ id: String, provider: String, on machineID: String?) async {
        error = ClientError.notConnected.localizedDescription
    }

    func reconnectAccount(_ id: String, provider: String, on machineID: String?) async {
        error = ClientError.notConnected.localizedDescription
    }

    // MARK: Commands: local model servers

    func reloadLocalServers(on machineID: String?) async throws {
        throw ClientError.notConnected
    }

    func connectLocalServer(url: String, key: String, replacing server: LocalModelServer?, on machineID: String?) async throws {
        throw ClientError.notConnected
    }

    func removeLocalServer(_ server: LocalModelServer, on machineID: String?) async throws {
        throw ClientError.notConnected
    }

    // MARK: Commands: Pi Durable SDK

    func requestSDK(_ action: PiDurableSDKAction, on machineID: String) {
        sdkStates[machineID, default: PiDurableSDKState()].error = ClientError.notConnected.localizedDescription
    }

    private func isProviderEnabled(for model: String) -> Bool {
        let provider = String(model.split(separator: "/", maxSplits: 1).first ?? "")
        return configuration.providers.contains(provider)
    }
}
