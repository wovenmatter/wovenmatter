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
                var status = parseSignIn(kind, output: result.combinedOutput, succeeded: result.succeeded)
                if kind == .codex, status.state == "verified", let root = DefaultAgentSupport.resources {
                    // Read public account metadata, never token files or a login flow.
                    if let result = try? LocalACPProcessRunner.run(executableURL: root.appending(path: "bin/node"),
                        arguments: [root.appending(path: "src/sign-in-status.mjs").path, "--codex-account", executable.path],
                        environment: environment, timeout: 12), result.succeeded,
                       let accounts = try? JSONDecoder().decode([AgentSignInStatus.Account].self,
                           from: Data(result.combinedOutput.utf8)), !accounts.isEmpty {
                        status.accounts = accounts
                    }
                }
                return status
            } catch { return status(kind, state: "check_failed") }
        }.value
    }

    public static func parseSignIn(_ kind: AgentRuntimeKind, output: String, succeeded: Bool) -> AgentSignInStatus {
        let text = output.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if kind == .opencode, succeeded, !openCodeStoredAccounts(text).isEmpty {
            return status(kind, state: "credentials_present", accounts: openCodeStoredAccounts(text))
        }
        if kind == .opencode, succeeded,
           let regex = try? NSRegularExpression(pattern: #"\b(\d+) (?:credentials?|environment variables?)\b"#) {
            let counts = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
            }
            if !counts.isEmpty {
                return status(kind, state: counts.contains { $0 > 0 } ? "credentials_present" : "sign_in_required", accounts: accountDetails(kind, text: text))
            }
        }
        if matches(#"not (?:logged|signed) in|not authenticated|login required|"loggedIn"\s*:\s*false|"authenticated"\s*:\s*false"#) {
            return status(kind, state: "sign_in_required")
        }
        if succeeded, matches(#"logged in|signed in|"loggedIn"\s*:\s*true|"authenticated"\s*:\s*true"#) {
            return status(kind, state: "verified", accounts: accountDetails(kind, text: text))
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

    static func accountDetails(_ kind: AgentRuntimeKind, text: String) -> [AgentSignInStatus.Account] {
        func label(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.count <= 160,
                  !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
                  !value.contains("sk-"), !value.contains("Bearer "), !value.hasPrefix("eyJ") else { return nil }
            return value
        }
        if kind == .claudeCode, let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let method = json["authMethod"] as? String
            let name = label(json["email"]) ?? label(json["apiKeyName"])
            if method == "claude.ai" { return [.init(method: "Claude subscription", name: name)] }
            if ["api_key", "apiKey", "api-key"].contains(method ?? "") {
                return [.init(method: "API key", name: name)]
            }
        }
        if kind == .opencode {
            let stored = openCodeStoredAccounts(text)
            if !stored.isEmpty { return stored }
            let pattern = #"(?m)^[│┃\s]*[●•]\s+([\p{L}0-9 ._()/-]+?)\s+(oauth|api|api_key|[A-Z][A-Z0-9_]*(?:API_KEY|TOKEN))\s*$"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    guard let provider = Range(match.range(at: 1), in: text), let method = Range(match.range(at: 2), in: text),
                          let name = label(String(text[provider])) else { return nil }
                    let value = String(text[method])
                    return .init(method: value == "oauth" ? "OAuth" : value.hasSuffix("API_KEY") || value.hasSuffix("TOKEN") ? "Environment key · " + value : "API key", name: name)
                }
            }
        }
        if text.localizedCaseInsensitiveContains("using ChatGPT") { return [.init(method: "ChatGPT", name: nil)] }
        if text.localizedCaseInsensitiveContains("API key") { return [.init(method: "API key", name: nil)] }
        if text.localizedCaseInsensitiveContains("OAuth") { return [.init(method: "OAuth", name: nil)] }
        return []
    }

    /// OpenCode v2 lists provider, account label, and storage state in columns.
    /// Recognize only complete stored rows; arbitrary successful output is not
    /// evidence of credentials, and saved credentials do not verify provider access.
    private static func openCodeStoredAccounts(_ text: String) -> [AgentSignInStatus.Account] {
        let pattern = #"(?m)^[\t ]*([^\r\n]+?)[\t ]{2,}([^\r\n]+?)[\t ]{2,}stored[\t ]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let providerRange = Range(match.range(at: 1), in: text),
                  let accountRange = Range(match.range(at: 2), in: text) else { return nil }
            let provider = String(text[providerRange]).trimmingCharacters(in: .whitespaces)
            let account = String(text[accountRange]).trimmingCharacters(in: .whitespaces)
            let name = provider == account || account == "API key" || account == "OAuth"
                ? provider : provider + " · " + account
            guard !name.isEmpty, name.count <= 160,
                  !name.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
                  !name.contains("sk-"), !name.contains("Bearer "), !name.hasPrefix("eyJ") else { return nil }
            return .init(method: account == "API key" ? "API key" : account == "OAuth" ? "OAuth" : "Saved credential", name: name)
        }
    }

    private static func status(_ kind: AgentRuntimeKind, state: String, accounts: [AgentSignInStatus.Account] = []) -> AgentSignInStatus {
        let detail: String = switch state {
        case "verified": "Already signed in on this Mac."
        case "credentials_present": "Saved credentials found. Provider access has not been verified."
        case "sign_in_required": "Sign in to use this harness."
        case "not_installed": "Choose this harness to install it."
        default: "Sign-in could not be confirmed. You can check again or continue setup later."
        }
        return AgentSignInStatus(id: kind.rawValue, name: kind.displayName, state: state, detail: detail, accounts: accounts)
    }
}
