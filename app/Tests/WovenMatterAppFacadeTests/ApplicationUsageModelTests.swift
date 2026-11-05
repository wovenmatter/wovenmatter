import Foundation
import Observation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

// This probe exercises only preferences and the backend proxy. It never refreshes
// provider data, accesses credentials or starts a provider CLI.
@MainActor struct ApplicationUsageModelTests {
    @Test func preferenceRestorationObservableConsentAndIdempotentConsent() async throws {
        let suite = "wovenmatter-usage-model-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UsageProviderPreferences(defaults: defaults).save([.codex])
        defaults.set(true, forKey: "wovenmatter.openrouter-credential.configured")

        let model = ApplicationUsageModel(applicationDefaults: defaults)
        #expect(model.enabledUsageProviders == Set(ProviderKind.supportedAccounts))
        #expect(model.isOpenRouterCredentialConfigured)
        #expect(!model.hasAcknowledgedCredentialAccessDisclosure)
        #expect(model.localUsage == nil && !model.isRefreshingLocalUsage)

        let consentChanges = ChangeRecorder()
        withObservationTracking {
            _ = model.hasAcknowledgedCredentialAccessDisclosure
        } onChange: {
            consentChanges.record()
        }
        model.acknowledgeCredentialAccessDisclosure()
        #expect(consentChanges.count == 1)
        #expect(defaults.bool(forKey: "wovenmatter.credential-access.disclosure-acknowledged"))
        let restored = ApplicationUsageModel(applicationDefaults: defaults)
        #expect(restored.hasAcknowledgedCredentialAccessDisclosure)
        #expect(restored.enabledUsageProviders == Set(ProviderKind.supportedAccounts))

        let repeatedConsentChanges = ChangeRecorder()
        withObservationTracking {
            _ = model.hasAcknowledgedCredentialAccessDisclosure
        } onChange: {
            repeatedConsentChanges.record()
        }
        model.acknowledgeCredentialAccessDisclosure()
        #expect(repeatedConsentChanges.count == 0)
        let projection = ApplicationUsageModel(applicationDefaults: defaults)
        projection.isBackendProjection = true
        var requests: [String] = []
        let snapshot = model.backendSnapshot()
        projection.backendRequest = { method, data in
            requests.append(method)
            if method == "usage.command" {
                let command = try JSONDecoder().decode(BackendUsageCommand.self, from: data)
                if case .refresh(.last30Days, true, .manual) = command {} else {
                    Issue.record("Unexpected usage proxy command")
                }
            }
            return try JSONEncoder().encode(snapshot)
        }
        await projection.refreshLocalUsage(range: .last30Days, refreshLimits: true)
        #expect(requests == ["usage.command"])
        #expect(projection.enabledUsageProviders == model.enabledUsageProviders)
        projection.backendRequest = nil
        await projection.refreshLocalUsage(range: .last30Days)
        #expect(projection.localUsageError == BackendRPCError.unavailable.localizedDescription)
        // Backend snapshots serialize all provider selections without credentials.
        let bytes = try await model.handleBackendRequest(BackendRPCRequest(method: "usage.snapshot"))
        let decoded = try JSONDecoder().decode(BackendUsageSnapshot.self, from: bytes)
        #expect(decoded.enabledUsageProviders == model.enabledUsageProviders)
    }
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
