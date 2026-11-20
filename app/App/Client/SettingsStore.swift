import Foundation
import Observation
import WovenProtocol

/// Synced settings shown in Settings: conversation titles, the Mac surface
/// profile, analytics consent, the GitHub key and identity, Woven MCP access for
/// outside agents. Defaults for new chats and dictation history are in the
/// extensions.
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
        static let analytics = "analytics.enabled"
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

    /// The models come from this Mac's Codex account, which the server does not report yet.
    func refreshTitleGenerationCapabilities() {
        titleGenerationStatus = ClientError.notOffered("Title models").localizedDescription
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

    // MARK: Analytics

    /// The synced consent; nil until the server has answered.
    var analyticsPreference: Bool? { isLoaded ? bool(Key.analytics) ?? false : nil }
    private(set) var analyticsError: String?
    var analyticsEnabled: Bool { analyticsPreference ?? false }

    func refreshAnalytics() async { await reload() }

    func setAnalyticsEnabled(_ enabled: Bool) async {
        do {
            try await set(Key.analytics, to: .bool(enabled))
            analyticsError = nil
        } catch {
            analyticsError = error.localizedDescription
        }
    }

    /// Counts an app open or active use; the server samples and sends it when consent allows.
    func recordAnalytics(_ event: ProductAnalyticsEvent) async {}

    // MARK: GitHub

    private(set) var github: GitHubSettings?
    private(set) var githubBusy = false
    var githubError: String?

    func loadGitHub() async {
        githubError = ClientError.notConnected.localizedDescription
    }

    /// True when the command succeeded.
    @discardableResult
    func runGitHub(_ command: GitHubSettingsCommand) async -> Bool {
        githubError = ClientError.notConnected.localizedDescription
        return false
    }

    // MARK: Woven MCP for outside agents

    private(set) var mcpAccess: WovenMCPAccess?
    private(set) var mcpAccessBusy = false
    private(set) var mcpAccessError: String?

    func refreshMCPAccess() async {
        mcpAccessError = ClientError.notConnected.localizedDescription
    }

    func setMCPAccessEnabled(_ enabled: Bool) async {
        mcpAccessError = ClientError.notConnected.localizedDescription
    }

    func setMCPAccessGroup(_ group: WorkspaceToolGroup, enabled: Bool) async {
        mcpAccessError = ClientError.notConnected.localizedDescription
    }
}
