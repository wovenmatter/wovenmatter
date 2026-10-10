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
    var accounts: [String: [ProviderConnectionAccounts.Account]]
    var cursorAccountStatus: String
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

    @MainActor init(_ model: DefaultAgentSettingsModel) {
        localServers = model.localServers
        scope = model.scope; settings = model.settings; catalog = model.catalog; providers = model.providers
        catalogIncludesAllModels = model.catalogIncludesAllModels
        resolvedDefaultModelID = model.resolvedDefaultModelID
        searchConfigured = model.searchConfigured; accounts = model.accounts
        cursorAccountStatus = model.cursorAccountStatus; signInProvider = model.signInProvider
        signInOutcome = model.signInOutcome
        busy = model.busy; error = model.error; notice = model.notice
        signInURL = model.signInURL; signInCode = model.signInCode
        prompt = model.prompt; promptID = model.promptID
        promptOptions = model.promptOptions.map { .init(id: $0.id, label: $0.label) }
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
            let c = try JSONDecoder().decode(BackendConnectionsCommand.self, from: payload)
            switch c.action {
            case "localServers": break
            case "connectServer":
                let enteredKey = (c.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let existingServerID = c.server?.id
                let savedKey = try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false) {
                    enteredKey.isEmpty ? try existingServerID.flatMap { try DefaultAgentSupport.key($0) } : enteredKey
                }
                guard let savedKey, !savedKey.isEmpty else { throw DefaultAgentError.message("Enter the server API key.") }
                _ = try await LocalModelServerStore.connect(url: c.label ?? "", key: savedKey, replacing: c.server)
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
            case "cursorStatus": await model.refreshCursorStatus()
            case "cursorSignIn": model.signInCursor()
            case "scope": model.changeScope(c.value ?? "global")
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
        let servers = LocalModelServerStore.servers
        if model.localServers != servers { model.localServers = servers }
        return try JSONEncoder().encode(BackendConnectionsSnapshot(model))
    }
}
