import Foundation

/// Names new chats from their first message with the Codex account on this Mac.
struct ConversationTitleGenerationSettings: Hashable, Sendable {
    var isEnabled = false
    var model = ""
    var thinking = ""
}

/// The models and thinking levels the Codex account offers for titles.
struct TitleGenerationCapabilities: Hashable, Sendable {
    var models: [String]
    var thinkingLevels: [String]
}

/// The theme and sidebar layout, synced so every Mac looks the same.
struct MacSurfaceProfile: Hashable, Sendable {
    var theme: String
    var sidebarStyle: String
}

// MARK: - GitHub

struct GitHubPublicKey: Hashable, Sendable {
    var publicKey: String
    var fingerprint: String
    var type: String
    var comment: String?
}

/// Author and committer on every commit. Blank fields keep each machine's own git settings.
struct GitHubGitIdentity: Hashable, Sendable {
    var name = ""
    var email = ""
}

/// Which places get the key: machines by machine ID, bots by bot ID. A place
/// never switched follows `newPlaces`.
struct GitHubAccess: Hashable, Sendable {
    var newPlaces = true
    var places: [String: Bool] = [:]

    func allows(_ place: String) -> Bool { places[place.lowercased()] ?? newPlaces }
}

/// What Settings → GitHub shows. Never the private key.
struct GitHubSettings: Hashable, Sendable {
    var key: GitHubPublicKey?
    var identity = GitHubGitIdentity()
    var access = GitHubAccess()
}

enum GitHubSettingsCommand: Hashable, Sendable {
    case generate
    case importKey(privateKey: String)
    case removeKey
    case saveIdentity(GitHubGitIdentity)
    case setPlace(String, allowed: Bool)
    /// The places Settings lists keep what they have now.
    case setNewPlaces(Bool, listed: [String])
}

enum GitHubSSHKeys {
    static let openSSHHeader = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
}

// MARK: - Woven MCP for outside agents

/// Whether agents outside Woven Matter may reach the Woven MCP on the tailnet, and which tools.
struct WovenMCPAccess: Hashable, Sendable {
    var isEnabled: Bool
    var groups: Set<WorkspaceToolGroup>
    var endpointURL: String
    var exposureError: String?
}

// MARK: - Analytics

enum ProductAnalyticsPolicy {
    static let url = URL(string: "https://wovenmatter.com/privacy")!
}

enum ProductAnalyticsEvent: Hashable, Sendable {
    case interfaceOpened
    case active
}
