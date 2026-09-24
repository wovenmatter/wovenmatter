import Foundation
import Observation
import WovenMatterCore
import WovenMatterDashboardStore

// This probe exercises only preferences and rejected actions. It never refreshes
// provider data, accesses credentials or starts a provider CLI.
@main
struct ApplicationUsageModelTests {
    @MainActor
    static func main() async throws {
        let suite = "wovenmatter-usage-model-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UsageProviderPreferences(defaults: defaults).save([.codex])
        CodexUsageWorkspacePreferences(defaults: defaults).save(selectedWorkspaceID: "saved-workspace")
        defaults.set(true, forKey: "wovenmatter.openrouter-credential.configured")

        let model = ApplicationUsageModel(applicationDefaults: defaults)
        precondition(model.enabledUsageProviders == [.codex])
        precondition(model.selectedCodexUsageWorkspaceID == "saved-workspace")
        precondition(model.isOpenRouterCredentialConfigured)
        precondition(!model.hasAcknowledgedCredentialAccessDisclosure)
        precondition(model.localUsage == nil && !model.isRefreshingLocalUsage)

        let consentChanges = ChangeRecorder()
        withObservationTracking {
            _ = model.hasAcknowledgedCredentialAccessDisclosure
        } onChange: {
            consentChanges.record()
        }
        model.acknowledgeCredentialAccessDisclosure()
        precondition(consentChanges.count == 1)
        precondition(defaults.bool(forKey: "wovenmatter.credential-access.disclosure-acknowledged"))
        let restored = ApplicationUsageModel(applicationDefaults: defaults)
        precondition(restored.hasAcknowledgedCredentialAccessDisclosure)
        precondition(restored.enabledUsageProviders == [.codex])
        precondition(restored.selectedCodexUsageWorkspaceID == "saved-workspace")

        let repeatedConsentChanges = ChangeRecorder()
        withObservationTracking {
            _ = model.hasAcknowledgedCredentialAccessDisclosure
        } onChange: {
            repeatedConsentChanges.record()
        }
        model.acknowledgeCredentialAccessDisclosure()
        precondition(repeatedConsentChanges.count == 0)

        let errorChanges = ChangeRecorder()
        withObservationTracking {
            _ = model.localUsageError
        } onChange: {
            errorChanges.record()
        }
        model.signInUsageProvider(.cursor)
        precondition(errorChanges.count == 1)
        precondition(model.localUsageError == "Enable Cursor usage tracking before signing in.")
        precondition(model.signingInUsageProviders.isEmpty)
        precondition(model.enabledUsageProviders == [.codex])

        let connectionRequests = ChangeRecorder()
        let observer = NotificationCenter.default.addObserver(forName: .init("wovenmatter.open-connections"), object: nil, queue: nil) { _ in
            connectionRequests.record()
        }
        model.signInUsageProvider(.claude)
        NotificationCenter.default.removeObserver(observer)
        precondition(connectionRequests.count == 1)
        precondition(model.signingInUsageProviders.isEmpty)

        // An unlisted workspace must not alter the saved selection or start work.
        await model.selectCodexUsageWorkspace("unlisted-workspace", range: .last30Days)
        precondition(model.selectedCodexUsageWorkspaceID == "saved-workspace")
        precondition(CodexUsageWorkspacePreferences(defaults: defaults).selectedWorkspaceID == "saved-workspace")
        precondition(model.localUsage == nil && !model.isRefreshingLocalUsage)
        print("Application usage: preference restoration, observable consent/error changes, idempotent consent and rejected-action guards passed.")
    }
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
