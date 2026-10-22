import Foundation
import WovenMatterCore

/// Read-only setup inventory. This type never starts login or changes credentials.
public enum HarnessOnboarding {
    public static let runtimes: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild, .opencode]
    public static let preferenceKey = "wovenmatter.harness-setup.state"

    /// Capture before opening the database, including when a backend owns it.
    public static func prepareFirstLaunch(defaults: UserDefaults, hasExistingWorkspace: Bool,
                                          hasExistingPreferences: Bool) {
        guard defaults.string(forKey: preferenceKey) == nil else { return }
        defaults.set(hasExistingWorkspace || hasExistingPreferences ? "dismissed" : "pending",
                     forKey: preferenceKey)
    }

    public static func checkSignIn(_ kind: AgentRuntimeKind, executable: URL?) async -> AgentSignInStatus {
        guard let executable else { return status(kind, state: "not_installed") }
        let arguments: [String]
        switch kind {
        case .codex: arguments = ["login", "status"]
        case .claudeCode: arguments = ["auth", "status", "--json"]
        case .grokBuild: arguments = ["models"]
        case .opencode: arguments = ["auth", "list"]
        default: return status(kind, state: "not_checked")
        }
        return await Task.detached(priority: .utility) {
            do {
                let environment = ProcessInfo.processInfo.environment.merging([
                    "PATH": LocalACPRuntimeResolver.executableSearchPath,
                    "NO_OPEN_BROWSER": "1", "BROWSER": "/usr/bin/false",
                ]) { _, new in new }
                let result = try LocalACPProcessRunner.run(executableURL: executable, arguments: arguments,
                    environment: environment, timeout: 10)
                return parseSignIn(kind, output: result.combinedOutput, succeeded: result.succeeded)
            } catch { return status(kind, state: "check_failed") }
        }.value
    }

    public static func parseSignIn(_ kind: AgentRuntimeKind, output: String, succeeded: Bool) -> AgentSignInStatus {
        let text = output.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if kind == .opencode, succeeded,
           let regex = try? NSRegularExpression(pattern: #"\b(\d+) (?:credentials?|environment variables?)\b"#) {
            let counts = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
            }
            if !counts.isEmpty {
                return status(kind, state: counts.contains { $0 > 0 } ? "credentials_present" : "sign_in_required")
            }
        }
        if matches(#"not (?:logged|signed) in|not authenticated|login required|"loggedIn"\s*:\s*false|"authenticated"\s*:\s*false"#) {
            return status(kind, state: "sign_in_required")
        }
        if succeeded, matches(#"logged in|signed in|"loggedIn"\s*:\s*true|"authenticated"\s*:\s*true"#) {
            return status(kind, state: "verified")
        }
        return status(kind, state: succeeded ? "not_checked" : "check_failed")
    }

    /// A script for the user's explicit Sign in action. Building this value
    /// performs no authentication and contains no credentials.
    public static func signInScript(_ kind: AgentRuntimeKind, executable: URL, searchPath: String) -> String? {
        let arguments: [String]
        switch kind {
        case .codex: arguments = ["login"]
        case .claudeCode: arguments = ["auth", "login"]
        case .grokBuild: arguments = ["login", "--oauth"]
        case .opencode: arguments = ["auth", "login"]
        default: return nil
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "#!/bin/zsh\nexport PATH=" + quote(searchPath) + "\n"
            + ([executable.path] + arguments).map(quote).joined(separator: " ") + "\n"
    }

    private static func status(_ kind: AgentRuntimeKind, state: String) -> AgentSignInStatus {
        let detail: String = switch state {
        case "verified": "Already signed in on this Mac."
        case "credentials_present": "Saved credentials found. Provider access has not been verified."
        case "sign_in_required": "Sign in to use this harness."
        case "not_installed": "Choose this harness to install it."
        default: "Sign-in could not be confirmed. You can check again or continue setup later."
        }
        return AgentSignInStatus(id: kind.rawValue, name: kind.displayName, state: state, detail: detail)
    }
}
