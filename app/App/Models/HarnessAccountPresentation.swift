import Foundation
import WovenMatterClient
import WovenMatterCore

/// Installation and transport readiness are not proof of account authentication.
enum HarnessAccountPresentation {
    static func providerSummary(_ statuses: [AgentSignInStatus]) -> String {
        let providers = statuses.filter { ProviderConnectionID(rawValue: $0.id) != nil }
        guard !providers.isEmpty else { return "Not checked" }
        let count = providers.filter { ["verified", "credentials_present"].contains($0.state) }.count
        return count == 0 ? "No accounts connected" : "\(count) account\(count == 1 ? "" : "s") with credentials"
    }

    static func remoteLabel(_ harness: RemoteHarnessStatus) -> String {
        if harness.id == .defaultAgent { return "Manage provider accounts" }
        switch harness.authenticationStatus {
        case "required": return "Sign-in required"
        case "configured": return "Credentials present"
        case "verified": return "Signed in"
        default: return "Not checked"
        }
    }
}

/// Selections add harnesses; reopening setup never removes installed software.
struct RemoteHarnessSetupSelection {
    var selected: Set<AgentRuntimeKind> = [.defaultAgent]
    var ordered: [AgentRuntimeKind] {
        AgentRuntimeKind.allCases.filter { selected.contains($0) }.sorted { $0.presentationRank < $1.presentationRank }
    }
    mutating func select(_ kind: AgentRuntimeKind, enabled: Bool) {
        guard kind != .defaultAgent else { return }
        if enabled { selected.insert(kind) } else { selected.remove(kind) }
    }
}
