import Foundation
import WovenMatterCore

/// In-app sign-in for native harnesses on this Mac: which command each sign-in runs,
/// how to sign out, and how to read the link and code a command prints. Building these
/// values starts nothing; the app runs a command only when the user presses Sign in or
/// Remove account. OpenCode keeps its own interactive `opencode auth login`.
public enum HarnessSignInFlow {
    public struct Method: Identifiable, Equatable, Sendable {
        /// What the user types into the command.
        public enum Input: Equatable, Sendable {
            case none
            /// A code shown on the sign-in page, sent while the command waits.
            case codeFromPage(label: String)
            /// A key read from standard input before the command finishes.
            case keyBeforeStart(label: String)
        }

        public let id: String
        public let title: String
        public let arguments: [String]
        public let input: Input

        public init(id: String, title: String, arguments: [String], input: Input = .none) {
            self.id = id; self.title = title; self.arguments = arguments; self.input = input
        }
    }

    /// Codex and Grok Build use device codes: a link plus a one-time code. Claude Code
    /// uses its regular browser sign-in on this Mac, with a field for the page's code in
    /// case Claude asks for it.
    public static func methods(_ kind: AgentRuntimeKind) -> [Method] {
        switch kind {
        case .codex:
            [.init(id: "chatgpt", title: "Sign in with ChatGPT", arguments: ["login", "--device-auth"]),
             .init(id: "openai-api-key", title: "Use an OpenAI API key", arguments: ["login", "--with-api-key"],
                   input: .keyBeforeStart(label: "OpenAI API key"))]
        case .claudeCode:
            [.init(id: "claude-account", title: "Sign in with Claude", arguments: ["auth", "login", "--claudeai"],
                   input: .codeFromPage(label: "Code from the Claude sign-in page")),
             .init(id: "anthropic-console", title: "Sign in with Anthropic Console", arguments: ["auth", "login", "--console"],
                   input: .codeFromPage(label: "Code from the Anthropic sign-in page"))]
        case .grokBuild:
            [.init(id: "grok-account", title: "Sign in with Grok", arguments: ["login", "--device-auth"])]
        default:
            []
        }
    }

    /// Signs the harness out on this Mac. OpenCode removes one saved credential at a time.
    public static func signOutArguments(_ kind: AgentRuntimeKind) -> [String]? {
        switch kind {
        case .codex: ["logout"]
        case .claudeCode: ["auth", "logout"]
        case .grokBuild: ["logout"]
        default: nil
        }
    }

    public static func openCodeRemoveArguments(target: String, credential: String) -> [String] {
        ["auth", "logout", target, credential]
    }

    /// Runs a sign-out command without a browser; true when it succeeds.
    public static func runSignOut(executable: URL, arguments: [String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let environment = ProcessInfo.processInfo.environment.merging([
                "PATH": LocalACPRuntimeResolver.executableSearchPath, "BROWSER": "/usr/bin/false", "NO_OPEN_BROWSER": "1",
            ]) { _, new in new }
            return (try? LocalACPProcessRunner.run(executableURL: executable, arguments: arguments,
                environment: environment, timeout: 20))?.succeeded == true
        }.value
    }

    public struct Artifacts: Equatable, Sendable {
        public var url: URL?
        public var code: String?
        public init(url: URL? = nil, code: String? = nil) { self.url = url; self.code = code }
    }

    /// The first HTTPS link and the one-time code in a command's output. Matches the
    /// remote workspace service, so both places show the same link and code.
    public static func artifacts(_ output: String) -> Artifacts {
        let text = sanitized(output)
        let urls = matches(#"https?://[^\s<>"']+"#, in: text)
            .map { $0.replacingOccurrences(of: #"[),.;]+$"#, with: "", options: .regularExpression) }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "https" && $0.host != nil }
        let urlCode = urls.lazy.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "user_code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }.first
        return Artifacts(url: urls.first, code: urlCode ?? promptedCode(text) ?? labeledCode(text))
    }

    static func sanitized(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .unicodeScalars.filter { $0 == "\n" || $0 == "\t" || (0x20...0x7E).contains($0.value) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    private static func labeledCode(_ text: String) -> String? {
        let pattern = #"(?:one[- ]time|device|authorization|confirm\s+this)?\s*code(?:\s+in\s+your\s+browser)?(?:\s+is)?\s*[:\-]?\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return normalizedCode(String(text[range]))
    }

    private static func promptedCode(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let label = #"\b(?:(?:one[- ]time|device|authorization|confirmation)\s+)?code\b"#
        for (index, line) in lines.enumerated()
        where line.range(of: label, options: [.regularExpression, .caseInsensitive]) != nil {
            for offset in 1...3 where index + offset < lines.count {
                if let code = normalizedCode(lines[index + offset]) { return code }
            }
        }
        return nil
    }

    private static func normalizedCode(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespaces)
        guard candidate.range(of: #"^[A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*$"#, options: .regularExpression) != nil,
              !["AUTHORIZATION", "CONFIRMATION", "CONTINUE", "BROWSER", "DEVICE", "LOGIN", "OPENAI", "CHATGPT"].contains(candidate)
        else { return nil }
        return candidate
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
