import Foundation
import Observation

/// Synced settings shown in Settings: conversation titles, the Mac surface
/// profile, analytics consent, the GitHub key and identity, Woven MCP access for
/// outside agents. Defaults for new chats and dictation history are in the
/// extensions.
@MainActor
@Observable
final class SettingsStore {
    init() {}

    // MARK: Conversation titles

    private(set) var titleGenerationSettings = ConversationTitleGenerationSettings()
    private(set) var titleGenerationCapabilities: TitleGenerationCapabilities?
    private(set) var titleGenerationStatus = ClientError.notConnected.localizedDescription
    private(set) var isRefreshingTitleGenerationCapabilities = false

    func setTitleGenerationEnabled(_ enabled: Bool) {
        titleGenerationStatus = ClientError.notConnected.localizedDescription
    }

    func setTitleGenerationModel(_ model: String) {
        titleGenerationStatus = ClientError.notConnected.localizedDescription
    }

    func setTitleGenerationThinking(_ thinking: String) {
        titleGenerationStatus = ClientError.notConnected.localizedDescription
    }

    func refreshTitleGenerationCapabilities() {
        titleGenerationStatus = ClientError.notConnected.localizedDescription
    }

    // MARK: Surface profile

    private(set) var surfaceProfile: MacSurfaceProfile?

    /// Sends the theme and sidebar layout this Mac stores in UserDefaults to the synced settings.
    func persistMacSurfaceProfileFromUserDefaults() {}

    // MARK: Analytics

    /// The synced consent; nil until the server has answered.
    private(set) var analyticsPreference: Bool?
    private(set) var analyticsError: String?
    var analyticsEnabled: Bool { analyticsPreference ?? false }

    func refreshAnalytics() async {}

    func setAnalyticsEnabled(_ enabled: Bool) async {
        analyticsError = ClientError.notConnected.localizedDescription
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
