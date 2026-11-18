import Foundation
import WovenMatterClient
import WovenMatterCore

// Requests travel only over the private local backend transport. Never log payloads:
// saveKey and respond may contain credentials or device sign-in answers.
struct BackendConnectionsCommand: Codable {
    var action: String
    var provider: String? = nil
    var value: String? = nil
    var label: String? = nil
    var offset: Int? = nil
    var flag: Bool? = nil
    var remote: RemoteWorkspaceConfiguration? = nil
    var profile: String? = nil
    var removingAccount: String? = nil
    var reconnectingAccount: String? = nil
    var configuration: DefaultAgentSettings? = nil
    var configurationBase: DefaultAgentSettings? = nil
    var server: LocalModelServer? = nil
    /// The device the command was issued for (`DefaultAgentSettingsModel.device`).
    /// The background server runs it only while that device is still selected.
    var device: String? = nil
}

extension BackendConnectionsCommand {
    private static let providers = Set(ProviderConnectionID.allCases.map(\.rawValue))
    private static func isSubscription(_ id: String?) -> Bool { id.flatMap(ProviderConnectionID.init(rawValue:))?.isSubscription == true }
    private static func isLocalServer(_ id: String) -> Bool {
        id.hasPrefix("local-server-") && UUID(uuidString: String(id.dropFirst("local-server-".count))) != nil
    }
    private static func invalid() -> DefaultAgentError { .message("Choose a provider connection.") }

    /// Every command names only real provider connections: a caller's provider
    /// string never becomes another Keychain item.
    func validated() throws -> Self {
        if let provider {
            let catalog = action == "catalog" && (provider.isEmpty || Self.isLocalServer(provider))
            guard Self.providers.contains(provider) || catalog else { throw Self.invalid() }
        }
        switch action {
        case "saveKey": guard let provider, !Self.isSubscription(provider) else { throw Self.invalid() }
        case "select", "move", "remove": guard provider != nil else { throw Self.invalid() }
        case "reconnect", "signOut": guard Self.isSubscription(provider) else { throw Self.invalid() }
        case "refresh": guard provider == nil || Self.isSubscription(provider) else { throw Self.invalid() }
        default: break
        }
        return self
    }

    /// What another Mac may ask of this Mac's own sign-ins
    /// (`/v1/connections/command`): an explicit list of commands, each with only
    /// the arguments it needs. Device selection, Keychain checks, other devices
    /// (`remote`) and the helper's internal arguments are never accepted.
    func forMember() throws -> Self {
        var command = try validated()
        let refused = DefaultAgentError.message("Only this Mac's own sign-ins can be changed here.")
        guard remote == nil else { throw refused }
        func short(_ value: String?, _ limit: Int) -> Bool { value.map { !$0.isEmpty && $0.count <= limit } ?? false }
        switch action {
        case "accounts", "localServers", "cancel", "claude":
            guard provider == nil, value == nil else { throw refused }
        case "scope":
            // That Mac's own chat settings, as its own page shows them.
            command.value = "global"
        case "configuration":
            guard configuration != nil else { throw refused }
        case "saveKey":
            guard short(value, 8_192), label.map({ $0.count <= 256 }) ?? true else { throw refused }
        case "select", "remove", "reconnect":
            guard short(value, 128) else { throw refused }
        case "move":
            guard short(value, 128), let offset, abs(offset) <= ProviderConnectionAccounts.limit else { throw refused }
        case "signOut": break
        case "respond":
            guard short(value, 8_192) else { throw refused }
        case "refresh":
            guard value == nil, profile == nil, removingAccount == nil, reconnectingAccount == nil else { throw refused }
        case "catalog":
            guard value == nil || value == "refresh" else { throw refused }
        case "connectServer":
            guard short(label, 2_048), (value ?? "").count <= 8_192 else { throw refused }
        case "removeServer":
            guard server != nil else { throw refused }
        default: throw refused
        }
        command.device = nil
        command.profile = nil; command.removingAccount = nil; command.reconnectingAccount = nil
        return command
    }
}

// Deliberately excludes credentials, helper output buffers and process handles.
struct BackendConnectionsSnapshot: Codable, Equatable {
    struct Option: Codable, Equatable { var id: String; var label: String }
    var localServers: [LocalModelServer]
    var scope: String
    var settings: DefaultAgentSettingsScope
    var catalog: [DefaultAgentSettingsModel.Model]
    var catalogIncludesAllModels: Bool?
    var resolvedDefaultModelID: String?
    var providers: [DefaultAgentSettingsModel.Provider]
    var searchConfigured: Bool
    var sharedAccounts: [String: [ProviderConnectionAccounts.Account]]?
    var accounts: [String: [ProviderConnectionAccounts.Account]]
    var signInProvider: String?
    var signInOutcome: DefaultAgentSettingsModel.SignInOutcome?
    var busy: Bool
    var error: String?
    var notice: String?
    var signInURL: URL?
    var signInCode: String?
    var prompt: String?
    var promptID: String?
    var promptOptions: [Option]
    /// The selected device and the device list; absent from another Mac's answer.
    var device: String?
    var devices: [SignInDevice]?

    @MainActor init(_ model: DefaultAgentSettingsModel) {
        localServers = model.localServers
        scope = model.scope; settings = model.settings; catalog = model.catalog; providers = model.providers
        catalogIncludesAllModels = model.catalogIncludesAllModels
        resolvedDefaultModelID = model.resolvedDefaultModelID
        searchConfigured = model.searchConfigured; accounts = model.accounts; sharedAccounts = model.sharedAccounts
        signInProvider = model.signInProvider
        signInOutcome = model.signInOutcome
        busy = model.busy; error = model.error; notice = model.notice
        signInURL = model.signInURL; signInCode = model.signInCode
        prompt = model.prompt; promptID = model.promptID
        promptOptions = model.promptOptions.map { .init(id: $0.id, label: $0.label) }
        device = model.device
        devices = model.devices
    }
}

@MainActor enum BackendConnectionsService {
    static func handle(method: String, payload: Data, model: DefaultAgentSettingsModel,
                       remoteWorkspaces: RemoteWorkspacesModel? = nil) async throws -> Data {
        if method == "connections.sdks.command" || method == "connections.sdks.snapshot" {
            let command = try JSONDecoder().decode(DefaultAgentSDKCommand.self, from: payload)
            if method == "connections.sdks.command" {
                guard let remoteWorkspaces else { throw BackendRPCError.remote("The workspace service is unavailable.") }
                model.sdks.start(command, remoteWorkspaces: remoteWorkspaces) { [weak model] in
                    model?.invalidateSDKCatalog(scopeKey: command.key)
                }
            }
            return try JSONEncoder().encode(model.sdks.state(for: command.key))
        }
        if method == "connections.command" {
            let c = try JSONDecoder().decode(BackendConnectionsCommand.self, from: payload).validated()
            // A window's account command runs on the device it was issued for. Another
            // window may have chosen a different device since: refuse rather than
            // change whichever device happens to be selected now.
            if let issued = c.device, !["device", "devices", "scope"].contains(c.action), issued != model.device {
                throw DefaultAgentError.message("The selected device changed. Try again.")
            }
            // Another Mac that could not be reached: never this Mac's sign-ins instead.
            if SignInDevice.kind(of: model.device) == .mac, !model.forwardsToPeer, !["device", "devices", "scope"].contains(c.action) {
                throw DefaultAgentError.message("That Mac isn't reachable from this Mac right now.")
            }
            // Another Mac's sign-ins: that Mac runs every command but device selection.
            if model.forwardsToPeer, !["device", "devices", "scope"].contains(c.action) {
                try await model.forwardToPeer(c)
                return try JSONEncoder().encode(BackendConnectionsSnapshot(model))
            }
            if ["localServers", "connectServer", "removeServer"].contains(c.action), try await model.linuxServerCommand(c) {
                return try JSONEncoder().encode(BackendConnectionsSnapshot(model))
            }
            switch c.action {
            case "devices": await model.loadDevicesAndWait()
            case "device":
                model.selectDevice(c.value ?? SignInDevice.localID)
                await model.settleForwarded()
            case "checkKeychain":
                try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false) {
                    try DefaultAgentSupport.checkKeychainAccess()
                }
            case "localServers": break
            case "connectServer":
                // A saved key is reused only for that saved server at its own URL.
                _ = try await LocalModelServerStore.connect(url: c.label ?? "", key: c.value, replacing: c.server)
            case "removeServer":
                if let server = c.server { try await LocalModelServerStore.remove(server) }
            case "configuration": if let value = c.configuration { model.applyConfiguration(value, base: c.configurationBase) }
            case "inherits": model.setInherits(c.flag ?? false)
            case "saveKey": _ = await model.saveKey(c.value ?? "", provider: c.provider ?? "", label: c.label)
            case "accounts": await model.loadAccountsAndWait()
            case "select": await model.selectAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "move": await model.moveAccount(c.value ?? "", provider: c.provider ?? "", offset: c.offset ?? 0)
            case "remove": await model.removeAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "reconnect": await model.reconnectAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "signOut": await model.signOut(c.provider ?? "", remote: c.remote)
            case "claude": model.signInClaude(remote: c.remote)
            case "scope": model.changeScope(c.value ?? "global"); await model.settleForwarded()
            case "cancel": model.cancel()
            case "respond": model.respond(c.value ?? "")
            case "catalog":
                model.loadCatalog(remote: c.remote, includeAllModels: c.flag ?? false, provider: c.provider, force: c.value == "refresh")
                if c.flag != true { await model.waitForEnabledMetadata() }
            case "refresh": model.refresh(remote: c.remote, login: c.provider, action: c.value, profile: c.profile,
                removingAccount: c.removingAccount, reconnectingAccount: c.reconnectingAccount)
            default: throw CocoaError(.featureUnsupported)
            }
        } else if method != "connections.snapshot" { throw CocoaError(.featureUnsupported) }
        if model.device == SignInDevice.localID {
            let servers = LocalModelServerStore.servers
            if model.localServers != servers { model.localServers = servers }
        }
        return try JSONEncoder().encode(BackendConnectionsSnapshot(model))
    }
}
