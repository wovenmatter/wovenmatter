import Foundation

/// Builds a native interactive command, without credentials or an app-owned
/// OAuth exchange. Only the Connections button launches it in Terminal.
public enum BuiltInClaudeSignIn {
    public struct Status: Decodable, Sendable {
        public let connected: Bool
        public let state: String
        public let account: String?
        public let detail: String
    }
    public static func status() async throws -> Status {
        let request = Data(#"{"action":"claude-status"}"#.utf8)
        return try await JSONDecoder().decode(Status.self, from: DefaultAgentControl.run(request))
    }
    public static func command(remote: RemoteWorkspaceConfiguration? = nil) throws -> String {
        let executable: URL
        let arguments: [String]
        if let remote {
            let launch = try RemoteHarnessLaunchResolver.resolve(
                configuration: remote, runtimeKind: .defaultAgent,
                processWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser
            ).launch
            executable = launch.executableURL
            arguments = launch.arguments.map { argument in
                if argument == "-T" { return "-t" }
                return argument.replacingOccurrences(of: "'--interactive'", with: "'--interactive' '--tty'")
                    .replacingOccurrences(of: "'--remote'", with: "'--claude-login'")
            }
        } else {
            guard let launch = DefaultAgentSupport.resolution().launchConfiguration else {
                throw DefaultAgentError.message(
                    "The bundled Claude helper is unavailable. Rebuild or reinstall Woven Matter.")
            }
            executable = launch.executableURL
            arguments = launch.arguments + ["--claude-login"]
        }
        return "exec " + ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
