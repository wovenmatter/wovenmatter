import Foundation

/// Installation and transport readiness are not proof of account authentication.
enum HarnessAccountPresentation {
    /// Pi Durable's provider accounts on one machine.
    static func providerSummary(_ statuses: [AgentSignInStatus]) -> String {
        guard !statuses.isEmpty else { return "Not checked" }
        let count = statuses.filter(\.hasCredentials).count
        return count == 0 ? "No accounts connected" : "\(count) account\(count == 1 ? "" : "s") with credentials"
    }

    /// A harness's account on one machine, for lists that link to its page.
    static func accountLabel(_ kind: AgentRuntimeKind, status: AgentSignInStatus?) -> String {
        if kind == .defaultAgent { return "Manage provider accounts" }
        return status?.label ?? "Not checked"
    }
}

/// Selections add harnesses; reopening setup never removes installed software.
struct HarnessSetupSelection {
    var selected: Set<AgentRuntimeKind> = [.defaultAgent]
    var ordered: [AgentRuntimeKind] {
        AgentRuntimeKind.allCases.filter { selected.contains($0) }.sorted { $0.presentationRank < $1.presentationRank }
    }
    mutating func select(_ kind: AgentRuntimeKind, enabled: Bool) {
        guard kind != .defaultAgent else { return }
        if enabled { selected.insert(kind) } else { selected.remove(kind) }
    }
}
