import Foundation

/// When to open the harness setup window: once, on the first launch.
@MainActor
final class HarnessSetupPresentation {
    static let shared = HarnessSetupPresentation()
    static let windowID = "harness-setup"
    static let preferenceKey = "wovenmatter.harness-setup.state"
    /// The harnesses setup offers to install. Pi Durable is included.
    static let runtimes: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild, .opencode]
    private var requestedAutomatically = false

    func prepareForLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.preferenceKey) == nil else { return }
        defaults.set("pending", forKey: Self.preferenceKey)
    }

    func takeAutomaticPresentation() -> Bool {
        guard !requestedAutomatically,
              UserDefaults.standard.string(forKey: Self.preferenceKey) == "pending" else { return false }
        requestedAutomatically = true
        return true
    }

    func dismiss() {
        UserDefaults.standard.set("dismissed", forKey: Self.preferenceKey)
    }
}
