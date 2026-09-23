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
    var server: LocalModelServer? = nil
}

// Deliberately excludes credentials, helper output buffers and process handles.
struct BackendConnectionsSnapshot: Codable, Equatable {
    struct Option: Codable, Equatable { var id: String; var label: String }
    var localServers: [LocalModelServer]
    var scope: String
    var settings: DefaultAgentSettingsScope
    var catalog: [DefaultAgentSettingsModel.Model]
    var providers: [DefaultAgentSettingsModel.Provider]
    var searchConfigured: Bool
    var accountLabels: [String: String]
    var accounts: [String: [ProviderConnectionAccounts.Account]]
    var cursorAccountStatus: String
    var signInProvider: String?
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
        searchConfigured = model.searchConfigured; accountLabels = model.accountLabels; accounts = model.accounts
        cursorAccountStatus = model.cursorAccountStatus; signInProvider = model.signInProvider
        busy = model.busy; error = model.error; notice = model.notice
        signInURL = model.signInURL; signInCode = model.signInCode
        prompt = model.prompt; promptID = model.promptID
        promptOptions = model.promptOptions.map { .init(id: $0.id, label: $0.label) }
    }
}

@MainActor enum BackendConnectionsService {
    static func handle(method: String, payload: Data, model: DefaultAgentSettingsModel) async throws -> Data {
        if method == "connections.command" {
            let c = try JSONDecoder().decode(BackendConnectionsCommand.self, from: payload)
            switch c.action {
            case "localServers": break
            case "connectServer":
                let enteredKey = (c.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let savedKey = enteredKey.isEmpty ? try c.server.flatMap { try DefaultAgentSupport.key($0.id) } : enteredKey
                guard let savedKey, !savedKey.isEmpty else { throw DefaultAgentError.message("Enter the server API key.") }
                _ = try await LocalModelServerStore.connect(url: c.label ?? "", key: savedKey, replacing: c.server)
            case "removeServer":
                if let server = c.server { try LocalModelServerStore.remove(server) }
            case "configuration": if let value = c.configuration { model.configuration = value }
            case "inherits": model.setInherits(c.flag ?? false)
            case "saveKey": _ = model.saveKey(c.value ?? "", provider: c.provider ?? "", label: c.label)
            case "accounts": model.loadAccounts()
            case "select": model.selectAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "move": model.moveAccount(c.value ?? "", provider: c.provider ?? "", offset: c.offset ?? 0)
            case "remove": model.removeAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "reconnect": model.reconnectAccount(c.value ?? "", provider: c.provider ?? "", remote: c.remote)
            case "signOut": model.signOut(c.provider ?? "", remote: c.remote)
            case "claude": model.signInClaude(remote: c.remote)
            case "cursorStatus": await model.refreshCursorStatus()
            case "cursorSignIn": model.signInCursor()
            case "scope": model.changeScope(c.value ?? "global")
            case "cancel": model.cancel()
            case "respond": model.respond(c.value ?? "")
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
