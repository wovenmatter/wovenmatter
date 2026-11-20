import Foundation

/// One part of a harness on one machine: the CLI, its connector, or a bundled piece.
struct HarnessComponent: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var path: String?
    var installedVersion: String?
    /// The version an update would bring, when one is available.
    var updateVersion: String?
    var isInstalled: Bool
    /// Installed by the system's package manager; it is updated there, not from Woven.
    var isSystemInstall: Bool
}

/// What a machine's server reports about one harness installed there.
struct HarnessInstallation: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case ready
        case notInstalled
        case signInRequired
        case unavailable
        case failed

        var displayName: String {
            switch self {
            case .ready: "Ready"
            case .notInstalled: "Not installed"
            case .signInRequired: "Sign-in required"
            case .unavailable: "Unavailable"
            case .failed: "Failed"
            }
        }
    }

    var id: AgentRuntimeKind { runtimeKind }
    let runtimeKind: AgentRuntimeKind
    var state: State
    var components: [HarnessComponent]
    var isInstalled: Bool
    /// Installed by the system's package manager on that machine.
    var isSystemInstall: Bool
    var path: String?
    /// False when the latest version could not be checked.
    var versionCheckAvailable: Bool
    /// Install or update attempts that failed in a row.
    var failureCount: Int
    /// Text to paste into an agent when repeated attempts fail.
    var diagnostic: String?

    var updateAvailable: Bool { components.contains { $0.updateVersion != nil } }

    /// The version of the harness people know, for "Installed · 1.2.3".
    var installedVersion: String? {
        components.first(where: { $0.displayName.hasSuffix(" CLI") })?.installedVersion
            ?? components.first?.installedVersion
    }

    var summary: String {
        components.map { component in
            let installed = component.isInstalled ? component.installedVersion.map { " \($0)" } ?? "" : " missing"
            return "\(component.displayName)\(installed)" + (component.updateVersion.map { " → \($0)" } ?? "")
        }.joined(separator: " · ")
    }
}

/// An install or update running on a machine.
enum HarnessOperation: Hashable, Sendable {
    case install
    case update
}

/// A harness's own sign-in on one machine, or a Pi Durable provider account. The harness
/// keeps its credentials; the server only reports whether it has them.
struct AgentSignInStatus: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case verified
        case credentialsPresent
        case signInRequired
        case notInstalled
        case notChecked
        case checkFailed
    }

    struct Account: Hashable, Sendable {
        var method: String
        var name: String?
        /// OpenCode keeps several keys and removes them one at a time, by this.
        var credential: String?
        var isRemovable: Bool { credential != nil }
    }

    let id: String
    var name: String
    var state: State
    var detail: String
    var accounts: [Account] = []

    var hasCredentials: Bool { state == .verified || state == .credentialsPresent }

    var label: String {
        switch state {
        case .verified: "Signed in"
        case .credentialsPresent: "Credentials present"
        case .signInRequired: "Sign-in required"
        case .notInstalled: "Not installed"
        case .notChecked: "Not checked"
        case .checkFailed: "Could not check"
        }
    }
}

/// One way to sign in to a harness. The server runs the harness's own command for it.
struct HarnessSignInMethod: Identifiable, Hashable, Sendable {
    /// What the person types into the sign-in.
    enum Input: Hashable, Sendable {
        case none
        /// A code shown on the sign-in page, sent while the sign-in waits.
        case codeFromPage(label: String)
        /// A key entered before the sign-in starts.
        case keyBeforeStart(label: String)
    }

    let id: String
    let title: String
    var input: Input = .none
}

/// The sign-ins each harness offers. OpenCode adds keys with its own picker in Terminal.
enum HarnessSignInFlow {
    typealias Method = HarnessSignInMethod

    static func methods(_ kind: AgentRuntimeKind) -> [Method] {
        switch kind {
        case .codex:
            [.init(id: "chatgpt", title: "Sign in with ChatGPT"),
             .init(id: "openai-api-key", title: "Use an OpenAI API key", input: .keyBeforeStart(label: "OpenAI API key"))]
        case .claudeCode:
            [.init(id: "claude-account", title: "Sign in with Claude",
                   input: .codeFromPage(label: "Code from the Claude sign-in page")),
             .init(id: "anthropic-console", title: "Sign in with Anthropic Console",
                   input: .codeFromPage(label: "Code from the Anthropic sign-in page"))]
        case .grokBuild:
            [.init(id: "grok-account", title: "Sign in with Grok")]
        case .defaultAgent, .opencode:
            []
        }
    }
}

/// One sign-in running on a machine's server: the link and code the harness printed.
struct HarnessSignInSession: Hashable, Sendable {
    enum State: Hashable, Sendable { case starting, waiting, succeeded, failed, cancelled }

    let runtimeKind: AgentRuntimeKind
    let method: HarnessSignInMethod
    var state: State = .starting
    var url: URL?
    var code: String?
    var error: String?
    var sentCode = false
    /// While no link has appeared, the command's last lines.
    var outputTail: String?
    var notice: String?

    var isActive: Bool { state == .starting || state == .waiting }

    var acceptsCode: Bool {
        if case .codeFromPage = method.input { return true }
        return false
    }

    var codeLabel: String {
        if case .codeFromPage(let label) = method.input { return label }
        return "Authorization code"
    }

    var message: String {
        switch state {
        case .starting: "Preparing sign-in…"
        case .waiting:
            if case .keyBeforeStart = method.input { "Saving your key…" }
            else if url != nil && code != nil { "Open the sign-in page and enter the one-time code." }
            else if url != nil { "Finish signing in to \(runtimeKind.displayName) in your browser." }
            else { "Preparing sign-in…" }
        case .succeeded: "Signed in to \(runtimeKind.displayName)."
        case .failed: error ?? "Sign-in didn't finish. Try again."
        case .cancelled: "Sign-in cancelled."
        }
    }
}
