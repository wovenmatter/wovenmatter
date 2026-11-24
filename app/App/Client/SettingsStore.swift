import Foundation
import Observation
import WovenProtocol

/// Synced settings shown in Settings: conversation titles, the Mac surface
/// profile, the GitHub key and identity, Woven MCP access for outside agents.
/// Defaults for new chats and dictation history are in the extensions.
@MainActor
@Observable
final class SettingsStore {
    /// Every synced setting by key, as the server last reported them.
    private(set) var values: [String: WovenProtocol.JSONValue] = [:]
    private(set) var error: String?
    /// The server has answered at least once.
    private(set) var isLoaded = false
    @ObservationIgnored weak var server: ServerConnection?

    init() {}

    func attach(_ server: ServerConnection) {
        self.server = server
    }

    /// Reads every setting again.
    func reload() async {
        guard let server else { return }
        do {
            values = Dictionary(try await server.call(ListSettings()).map { ($0.key, $0.value) },
                                uniquingKeysWith: { _, newest in newest })
            isLoaded = true
            error = nil
            applyDictationLanguage()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sets a synced setting for every machine; `.null` unsets it.
    func set(_ key: String, to value: WovenProtocol.JSONValue) async throws {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        let setting = try await server.call(SetSetting(key: key, value: value))
        values[setting.key] = setting.value
    }

    private func bool(_ key: String) -> Bool? {
        if case .bool(let value) = values[key] { value } else { nil }
    }

    private func string(_ key: String) -> String? {
        if case .string(let value) = values[key] { value } else { nil }
    }

    // MARK: Conversation titles

    private enum Key {
        static let titles = "titles.enabled"
        static let titleModel = "titles.model"
        static let titleThinking = "titles.thinking"
        static let theme = "mac.theme"
        static let sidebarStyle = "mac.sidebarStyle"
    }

    var titleGenerationSettings: ConversationTitleGenerationSettings {
        ConversationTitleGenerationSettings(isEnabled: bool(Key.titles) ?? false, model: string(Key.titleModel) ?? "",
                                            thinking: string(Key.titleThinking) ?? "")
    }
    private(set) var titleGenerationCapabilities: TitleGenerationCapabilities?
    private(set) var titleGenerationStatus = ""
    private(set) var isRefreshingTitleGenerationCapabilities = false

    func setTitleGenerationEnabled(_ enabled: Bool) { setTitle(Key.titles, .bool(enabled)) }

    func setTitleGenerationModel(_ model: String) { setTitle(Key.titleModel, .string(model)) }

    func setTitleGenerationThinking(_ thinking: String) { setTitle(Key.titleThinking, .string(thinking)) }

    /// The models and thinking levels Codex last reported on this Mac, which names new chats.
    func refreshTitleGenerationCapabilities() {
        guard let server, server.isConnected else { return titleGenerationStatus = ClientError.notConnected.localizedDescription }
        isRefreshingTitleGenerationCapabilities = true
        Task {
            defer { isRefreshingTitleGenerationCapabilities = false }
            do {
                guard let configuration = try await server.call(GetRuntimeConfiguration(runtime: .codex)) else {
                    titleGenerationStatus = RuntimeOptionsUnknown(runtime: .codex).localizedDescription
                    return
                }
                titleGenerationCapabilities = TitleGenerationCapabilities(models: configuration.models.map(\.id),
                                                                          thinkingLevels: configuration.thinkingLevels.map(\.id))
                titleGenerationStatus = ""
            } catch {
                titleGenerationStatus = error.localizedDescription
            }
        }
    }

    private func setTitle(_ key: String, _ value: WovenProtocol.JSONValue) {
        Task {
            do {
                try await set(key, to: value)
                titleGenerationStatus = ""
            } catch {
                titleGenerationStatus = error.localizedDescription
            }
        }
    }

    // MARK: Surface profile

    var surfaceProfile: MacSurfaceProfile? {
        guard let theme = string(Key.theme), let sidebarStyle = string(Key.sidebarStyle) else { return nil }
        return MacSurfaceProfile(theme: theme, sidebarStyle: sidebarStyle)
    }

    /// Sends the theme and sidebar layout this Mac stores in UserDefaults to the synced settings.
    func persistMacSurfaceProfileFromUserDefaults() {
        let defaults = UserDefaults.standard
        let theme = defaults.string(forKey: WovenTheme.storageKey) ?? WovenTheme.green.rawValue
        let sidebarStyle = defaults.string(forKey: SidebarStyle.storageKey) ?? SidebarStyle.defaultStyle.rawValue
        guard surfaceProfile != MacSurfaceProfile(theme: theme, sidebarStyle: sidebarStyle) else { return }
        Task {
            try? await set(Key.theme, to: .string(theme))
            try? await set(Key.sidebarStyle, to: .string(sidebarStyle))
        }
    }

    // MARK: Anonymous usage statistics

    /// On unless the person turned them off; the choice applies to every machine.
    var analyticsEnabled: Bool { bool(AnalyticsSettings.enabled) ?? true }
    private(set) var analyticsError: String?

    func setAnalyticsEnabled(_ enabled: Bool) async {
        do {
            try await set(AnalyticsSettings.enabled, to: .bool(enabled))
            analyticsError = nil
        } catch {
            analyticsError = error.localizedDescription
        }
    }

    // MARK: GitHub (in SettingsStore+GitHub.swift)

    var github: GitHubSettings?
    var githubBusy = false
    var githubError: String?

    // MARK: Woven MCP for outside agents

    /// Whether this Mac's server answers agents outside Woven Matter, their tools, and the command they start.
    private(set) var mcpAccess: OutsideAgentAccess?
    private(set) var mcpAccessBusy = false
    private(set) var mcpAccessError: String?

    func refreshMCPAccess() async { await performMCPAccess(GetOutsideAgentAccess()) }

    func setMCPAccessEnabled(_ enabled: Bool) async {
        guard let access = mcpAccess else { return }
        await performMCPAccess(SetOutsideAgentAccess(isEnabled: enabled, groups: access.groups))
    }

    func setMCPAccessGroup(_ group: ToolGroup, enabled: Bool) async {
        guard let access = mcpAccess else { return }
        var groups = access.groups
        if enabled { groups.insert(group) } else { groups.remove(group) }
        await performMCPAccess(SetOutsideAgentAccess(isEnabled: access.isEnabled, groups: groups))
    }

    private func performMCPAccess<R: Request>(_ request: R) async where R.Reply == OutsideAgentAccess {
        guard !mcpAccessBusy else { return }
        guard let server, server.isConnected else { return mcpAccessError = ClientError.notConnected.localizedDescription }
        mcpAccessBusy = true
        defer { mcpAccessBusy = false }
        do {
            mcpAccess = try await server.call(request)
            mcpAccessError = nil
        } catch {
            mcpAccessError = error.localizedDescription
        }
    }
}
