import Foundation

/// Reads native Claude account status without extracting its credentials.
public enum BuiltInClaudeSignIn {
    public struct Status: Decodable, Sendable {
        public let connected: Bool
        public let state: String
        public let account: String?
        public let detail: String
    }
    public static func status(profile: String? = nil) async throws -> Status {
        var body = ["action": "claude-status"]
        if let profile { body["profile"] = profile }
        let request = try JSONSerialization.data(withJSONObject: body)
        return try await JSONDecoder().decode(Status.self, from: DefaultAgentControl.run(request))
    }
}
