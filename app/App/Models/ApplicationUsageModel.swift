import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

private struct UsageAnalyticsRefreshKey: Hashable, Sendable {
    let range: String
    let enabledProviders: [String]
    let allowsCredentialAccess: Bool
}

private struct UsageLimitsRefreshKey: Hashable, Sendable {
    let enabledProviders: [String]
    let allowsCredentialAccess: Bool
    let keychainInteraction: String
    let interactiveProvider: String?
    let selectedCodexWorkspaceID: String?
}

/// Owns usage presentation, refresh lifetimes and preferences independently of workspace runs.
/// Provider access remains behind LocalUsageService and the existing explicit actions.
@MainActor
@Observable
final class ApplicationUsageModel {
    private(set) var localUsage: LocalUsageSnapshot?
    private(set) var localUsageError: String?
    private(set) var isRefreshingUsageAnalytics = false
    private(set) var isRefreshingUsageLimits = false
    private(set) var isAuthorizingUsageCredential = false
    var isRefreshingLocalUsage: Bool {
        isRefreshingUsageAnalytics || isRefreshingUsageLimits || isAuthorizingUsageCredential
    }
    private(set) var isOpenRouterCredentialConfigured = false
    private(set) var signingInUsageProviders: Set<ProviderKind> = []
    private(set) var hasAcknowledgedCredentialAccessDisclosure = false
    private(set) var enabledUsageProviders: Set<ProviderKind> = []
    private(set) var codexUsageWorkspaces: [CodexUsageWorkspace] = []
    private(set) var selectedCodexUsageWorkspaceID: String?
    @ObservationIgnored
    private let localUsageService = LocalUsageService()
    @ObservationIgnored
    private var usageAnalyticsRequestID: UUID?
    @ObservationIgnored
    private var usageLimitsRequestID: UUID?
    @ObservationIgnored
    private let usageAnalyticsRefreshCoordinator = UsageRefreshCoordinator<
        UsageAnalyticsRefreshKey,
        UsageAnalyticsSnapshot
    >()
    @ObservationIgnored
    private let usageLimitsRefreshCoordinator = UsageRefreshCoordinator<
        UsageLimitsRefreshKey,
        LocalUsageLimitsSnapshot
    >()
    @ObservationIgnored
    private let applicationDefaults: UserDefaults
    private static let openRouterCredentialConfiguredDefaultsKey =
        "wovenmatter.openrouter-credential.configured"
    private static let credentialAccessDisclosureDefaultsKey =
        "wovenmatter.credential-access.disclosure-acknowledged"

    /// Reads retained samples without refreshing providers or credentials.
    func recordedUsageSamples(from start: Date, to end: Date, limit: Int, offset: Int) async throws -> [UsageSample] {
        try await localUsageService.recordedSamples(from: start, to: end, limit: limit, offset: offset)
    }

    init(applicationDefaults: UserDefaults) {
        self.applicationDefaults = applicationDefaults
        isOpenRouterCredentialConfigured = applicationDefaults.bool(
            forKey: Self.openRouterCredentialConfiguredDefaultsKey
        )
        hasAcknowledgedCredentialAccessDisclosure = applicationDefaults.bool(
            forKey: Self.credentialAccessDisclosureDefaultsKey
        )
        selectedCodexUsageWorkspaceID = CodexUsageWorkspacePreferences(
            defaults: applicationDefaults
        ).selectedWorkspaceID
        enabledUsageProviders = UsageProviderPreferences(
            defaults: applicationDefaults
        ).enabledProviders
    }

    func refreshLocalUsage(
        range: UsageTimeRange,
        refreshLimits: Bool = false,
        reason: UsageRefreshReason = .manual,
        explicitCredentialAccess: Bool = false,
        interactiveProvider: ProviderKind? = nil
    ) async {
        localUsageError = nil
        prepareUsageSnapshot(range: range)
        let policy: UsageRefreshCoordinator<
            UsageAnalyticsRefreshKey,
            UsageAnalyticsSnapshot
        >.Policy = switch reason {
        case .manual, .credentialChanged:
            .force
        case .startup, .viewAppeared, .rangeChanged, .runCompleted, .periodic:
            .refresh
        }
        if refreshLimits {
            let keychainInteraction = UsageKeychainInteraction.resolve(
                refreshReason: reason,
                disclosureAcknowledged: hasAcknowledgedCredentialAccessDisclosure,
                explicitUserAction: explicitCredentialAccess && interactiveProvider != nil
            )
            async let analyticsRefresh: Void = refreshUsageAnalytics(
                range: range,
                reason: reason,
                policy: policy
            )
            async let limitsRefresh: Void = refreshUsageLimits(
                reason: reason,
                force: policy == .force,
                keychainInteraction: keychainInteraction,
                interactiveProvider: interactiveProvider
            )
            _ = await (analyticsRefresh, limitsRefresh)
        } else {
            await refreshUsageAnalytics(
                range: range,
                reason: reason,
                policy: policy
            )
        }
    }

    func usageDestinationAppeared(range: UsageTimeRange) async {
        updateSharedConnectionPresence()
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .viewAppeared
        )
    }
    func sharedConnectionsChanged() async {
        updateSharedConnectionPresence()
        await refreshLocalUsage(range: currentUsageRange, refreshLimits: true, reason: .credentialChanged)
    }
    private func updateSharedConnectionPresence() {
        guard let configured = try? DefaultAgentSupport.hasKey("openrouter") else { return }
        isOpenRouterCredentialConfigured = configured
        applicationDefaults.set(configured, forKey: Self.openRouterCredentialConfiguredDefaultsKey)
    }

    func usageAnalyticsSelected(range: UsageTimeRange) async {
        await refreshUsageAnalytics(
            range: range,
            reason: .viewAppeared,
            policy: .reuse
        )
    }

    private func refreshUsageAnalytics(
        range: UsageTimeRange,
        reason: UsageRefreshReason,
        policy: UsageRefreshCoordinator<
            UsageAnalyticsRefreshKey,
            UsageAnalyticsSnapshot
        >.Policy
    ) async {
        let enabledProviders = enabledUsageProviders
        let allowsCredentialAccess = isOpenRouterCredentialConfigured
            && hasAcknowledgedCredentialAccessDisclosure
            && enabledProviders.contains(.openRouter)
        let key = UsageAnalyticsRefreshKey(
            range: range.rawValue,
            enabledProviders: enabledProviders.map(\.rawValue).sorted(),
            allowsCredentialAccess: allowsCredentialAccess
        )
        let requestID = UUID()
        usageAnalyticsRequestID = requestID
        isRefreshingUsageAnalytics = true
        do {
            let analytics = try await usageAnalyticsRefreshCoordinator.value(
                for: key,
                policy: policy
            ) { [localUsageService] in
                try await localUsageService.analyticsSnapshot(
                    range: range,
                    refreshReason: reason,
                    enabledProviders: enabledProviders,
                    allowCredentialAccess: allowsCredentialAccess
                )
            }
            guard usageAnalyticsRequestID == requestID,
                  enabledUsageProviders == enabledProviders else { return }
            try Task.checkCancellation()
            let existing = localUsage
            localUsage = LocalUsageSnapshot(
                analytics: analytics,
                limits: existing?.limits ?? LocalUsageService.placeholderLimits(
                    enabledProviders: enabledProviders
                ),
                hasOpenRouterCredential: existing?.hasOpenRouterCredential
                    ?? isOpenRouterCredentialConfigured
            )
        } catch is CancellationError {
            // A forced refresh superseded this request. Its replacement owns the state.
        } catch {
            if usageAnalyticsRequestID == requestID, !Task.isCancelled {
                localUsageError = error.localizedDescription
            }
        }
        let isRefreshing = await usageAnalyticsRefreshCoordinator.isRefreshing
        if usageAnalyticsRequestID == requestID {
            isRefreshingUsageAnalytics = isRefreshing
        }
    }

    private func refreshUsageLimits(
        reason: UsageRefreshReason,
        force: Bool,
        keychainInteraction: UsageKeychainInteraction,
        interactiveProvider: ProviderKind?
    ) async {
        let enabledProviders = enabledUsageProviders
        let allowsCredentialAccess = isOpenRouterCredentialConfigured
            && hasAcknowledgedCredentialAccessDisclosure
            && enabledProviders.contains(.openRouter)
        let requestedCodexWorkspaceID = selectedCodexUsageWorkspaceID
        let key = UsageLimitsRefreshKey(
            enabledProviders: enabledProviders.map(\.rawValue).sorted(),
            allowsCredentialAccess: allowsCredentialAccess,
            keychainInteraction: keychainInteraction.rawValue,
            interactiveProvider: interactiveProvider?.rawValue,
            selectedCodexWorkspaceID: requestedCodexWorkspaceID
        )
        let requestID = UUID()
        usageLimitsRequestID = requestID
        isRefreshingUsageLimits = true
        do {
            let limits = try await usageLimitsRefreshCoordinator.value(
                for: key,
                policy: force ? .force : .refresh
            ) { [localUsageService] in
                try await localUsageService.limitsSnapshot(
                    refresh: true,
                    refreshReason: reason,
                    enabledProviders: enabledProviders,
                    allowCredentialAccess: allowsCredentialAccess,
                    keychainInteraction: keychainInteraction,
                    interactiveProvider: interactiveProvider,
                    selectedCodexWorkspaceID: requestedCodexWorkspaceID
                )
            }
            guard usageLimitsRequestID == requestID,
                  enabledUsageProviders == enabledProviders,
                  selectedCodexUsageWorkspaceID == requestedCodexWorkspaceID else { return }
            try Task.checkCancellation()
            codexUsageWorkspaces = limits.codexWorkspaces
            selectedCodexUsageWorkspaceID = limits.selectedCodexWorkspaceID
            let existing = localUsage
            localUsage = LocalUsageSnapshot(
                analytics: existing?.analytics ?? Self.emptyUsageAnalytics(range: currentUsageRange),
                limits: limits.accounts,
                hasOpenRouterCredential: limits.hasOpenRouterCredential
                    || isOpenRouterCredentialConfigured
            )
        } catch is CancellationError {
            // A forced refresh superseded this request. Its replacement owns the state.
        } catch {
            if usageLimitsRequestID == requestID, !Task.isCancelled {
                localUsageError = error.localizedDescription
            }
        }
        let isRefreshing = await usageLimitsRefreshCoordinator.isRefreshing
        if usageLimitsRequestID == requestID {
            isRefreshingUsageLimits = isRefreshing
        }
    }

    private func prepareUsageSnapshot(range: UsageTimeRange) {
        guard localUsage == nil else { return }
        localUsage = LocalUsageSnapshot(
            analytics: Self.emptyUsageAnalytics(range: range),
            limits: LocalUsageService.placeholderLimits(
                enabledProviders: enabledUsageProviders
            ),
            hasOpenRouterCredential: isOpenRouterCredentialConfigured
        )
    }

    private static func emptyUsageAnalytics(
        range: UsageTimeRange
    ) -> UsageAnalyticsSnapshot {
        UsageAnalyticsSnapshot(
            range: range,
            generatedAt: Date(),
            samples: [],
            sources: []
        )
    }

    var currentUsageRange: UsageTimeRange {
        let rawValue = UserDefaults.standard.string(
            forKey: "wovenmatter.usage.range"
        )
        return rawValue.flatMap(UsageTimeRange.init(rawValue:)) ?? .last30Days
    }

    func saveOpenRouterAPIKey(_ value: String, range: UsageTimeRange) async {
        guard !isAuthorizingUsageCredential else { return }
        isAuthorizingUsageCredential = true
        defer { isAuthorizingUsageCredential = false }
        do {
            acknowledgeCredentialAccessDisclosure()
            enableUsageProviderPreference(.openRouter)
            try await localUsageService.saveOpenRouterAPIKey(value)
            isOpenRouterCredentialConfigured = true
            applicationDefaults.set(
                true,
                forKey: Self.openRouterCredentialConfiguredDefaultsKey
            )
            await refreshLocalUsage(
                range: range,
                refreshLimits: true,
                reason: .credentialChanged
            )
        } catch {
            localUsageError = error.localizedDescription
        }
    }

    func deleteOpenRouterAPIKey(range: UsageTimeRange) async {
        guard !isAuthorizingUsageCredential else { return }
        isAuthorizingUsageCredential = true
        defer { isAuthorizingUsageCredential = false }
        do {
            try await localUsageService.deleteOpenRouterAPIKey()
            isOpenRouterCredentialConfigured = false
            applicationDefaults.set(
                false,
                forKey: Self.openRouterCredentialConfiguredDefaultsKey
            )
            disableUsageProviderPreference(.openRouter)
            await refreshLocalUsage(
                range: range,
                refreshLimits: true,
                reason: .credentialChanged
            )
        } catch {
            localUsageError = error.localizedDescription
        }
    }

    func acknowledgeCredentialAccessDisclosure() {
        guard !hasAcknowledgedCredentialAccessDisclosure else { return }
        hasAcknowledgedCredentialAccessDisclosure = true
        applicationDefaults.set(
            true,
            forKey: Self.credentialAccessDisclosureDefaultsKey
        )
    }

    // Global recovery shares the same authorization guard as usage actions.
    // ApplicationModel owns the cross-domain sequence; this owner retains the
    // only LocalUsageService and its credential/cache state.
    func beginCredentialAuthorization() -> Bool {
        guard !isAuthorizingUsageCredential else { return false }
        isAuthorizingUsageCredential = true
        return true
    }

    func endCredentialAuthorization() {
        isAuthorizingUsageCredential = false
    }

    func authorizeSavedCredentials() async throws {
        if isOpenRouterCredentialConfigured, enabledUsageProviders.contains(.openRouter) {
            try await localUsageService.authorizeOpenRouterCredentialAccess()
        }
        if enabledUsageProviders.contains(.claude) {
            try await localUsageService.authorizeClaudeCredentialAccess()
        }
    }

    func isUsageProviderEnabled(_ provider: ProviderKind) -> Bool {
        enabledUsageProviders.contains(provider)
    }

    func enableUsageProvider(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        guard !isAuthorizingUsageCredential else { return }
        isAuthorizingUsageCredential = true
        defer { isAuthorizingUsageCredential = false }
        acknowledgeCredentialAccessDisclosure()
        enableUsageProviderPreference(provider)
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .credentialChanged,
            explicitCredentialAccess: [.codex, .claude, .grok, .cursor].contains(provider),
            interactiveProvider: provider == .openRouter ? nil : provider
        )
    }

    func retryUsageProviderCredentialAccess(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        guard enabledUsageProviders.contains(provider),
              !isAuthorizingUsageCredential else { return }
        isAuthorizingUsageCredential = true
        defer { isAuthorizingUsageCredential = false }
        acknowledgeCredentialAccessDisclosure()
        if provider == .openRouter {
            do {
                try await localUsageService.authorizeOpenRouterCredentialAccess()
            } catch {
                localUsageError = error.localizedDescription
                return
            }
        }
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .credentialChanged,
            explicitCredentialAccess: [.codex, .claude, .grok, .cursor].contains(provider),
            interactiveProvider: provider == .openRouter ? nil : provider
        )
    }

    func selectCodexUsageWorkspace(
        _ workspaceID: String,
        range: UsageTimeRange
    ) async {
        guard enabledUsageProviders.contains(.codex),
              hasAcknowledgedCredentialAccessDisclosure,
              codexUsageWorkspaces.contains(where: { $0.id == workspaceID }),
              selectedCodexUsageWorkspaceID != workspaceID
        else { return }
        selectedCodexUsageWorkspaceID = workspaceID
        CodexUsageWorkspacePreferences(defaults: applicationDefaults)
            .save(selectedWorkspaceID: workspaceID)
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .credentialChanged
        )
    }

    func disableUsageProvider(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        disableUsageProviderPreference(provider)
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .credentialChanged
        )
    }

    private func enableUsageProviderPreference(_ provider: ProviderKind) {
        guard enabledUsageProviders.insert(provider).inserted else { return }
        persistEnabledUsageProviders()
    }

    private func disableUsageProviderPreference(_ provider: ProviderKind) {
        guard enabledUsageProviders.remove(provider) != nil else { return }
        persistEnabledUsageProviders()
    }

    private func persistEnabledUsageProviders() {
        UsageProviderPreferences(defaults: applicationDefaults).save(
            enabledUsageProviders
        )
    }

    func signInUsageProvider(_ provider: ProviderKind) {
        if [.codex, .grok, .openRouter, .openCodeGo].contains(provider) {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: "global")
            return
        }
        guard !signingInUsageProviders.contains(provider) else { return }
        guard enabledUsageProviders.contains(provider) else {
            localUsageError = "Enable \(provider.displayName) usage tracking before signing in."
            return
        }
        guard let command = Self.usageProviderSignInCommand(provider) else {
            localUsageError = "\(provider.displayName) sign-in is unavailable because its CLI is not installed."
            return
        }
        signingInUsageProviders.insert(provider)
        localUsageError = nil
        Task {
            defer { signingInUsageProviders.remove(provider) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = command.executable
                    process.arguments = command.arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw UsageProviderSignInError.failed(
                            provider.displayName,
                            process.terminationStatus
                        )
                    }
                }.value
                await refreshLocalUsage(
                    range: currentUsageRange,
                    refreshLimits: true,
                    reason: .credentialChanged,
                    explicitCredentialAccess: [.codex, .claude, .grok, .cursor].contains(provider),
                    interactiveProvider: provider == .openRouter ? nil : provider
                )
            } catch {
                localUsageError = error.localizedDescription
            }
        }
    }

    func reconnectSelectedCodexUsageWorkspace() {
        guard !signingInUsageProviders.contains(.codex),
              enabledUsageProviders.contains(.codex),
              hasAcknowledgedCredentialAccessDisclosure,
              let workspaceID = selectedCodexUsageWorkspaceID
        else { return }
        signingInUsageProviders.insert(.codex)
        localUsageError = nil
        Task {
            defer { signingInUsageProviders.remove(.codex) }
            do {
                guard let homeDirectory = await localUsageService
                    .codexWorkspaceHomeDirectory(workspaceID: workspaceID),
                      let command = Self.usageProviderSignInCommand(.codex)
                else {
                    throw UsageProviderSignInError.unavailable(
                        "The selected OpenAI workspace is no longer available."
                    )
                }
                try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = command.executable
                    process.arguments = command.arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["CODEX_HOME"] = homeDirectory.path
                    process.environment = environment
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw UsageProviderSignInError.failed(
                            "Codex / OpenAI",
                            process.terminationStatus
                        )
                    }
                }.value
                await refreshLocalUsage(
                    range: currentUsageRange,
                    refreshLimits: true,
                    reason: .credentialChanged
                )
            } catch {
                localUsageError = error.localizedDescription
            }
        }
    }

    private nonisolated static func usageProviderSignInCommand(
        _ provider: ProviderKind
    ) -> UsageProviderSignInCommand? {
        let executableName: String
        let arguments: [String]
        switch provider {
        case .codex:
            executableName = "codex"
            arguments = ["login"]
        case .claude:
            executableName = "claude"
            arguments = ["auth", "login", "--claudeai"]
        case .grok:
            executableName = "grok"
            arguments = ["login", "--oauth"]
        case .cursor:
            executableName = LocalACPRuntimeResolver.resolveExecutable(
                named: "cursor-agent"
            ) == nil ? "agent" : "cursor-agent"
            arguments = ["login"]
        case .openCodeGo:
            executableName = "opencode"
            arguments = ["auth", "login", "--provider", "opencode-go"]
        case .openRouter, .unknown:
            return nil
        }
        guard let executable = LocalACPRuntimeResolver.resolveExecutable(
            named: executableName
        ) else { return nil }
        return UsageProviderSignInCommand(
            executable: executable,
            arguments: arguments
        )
    }

}

private struct UsageProviderSignInCommand: Sendable {
    let executable: URL
    let arguments: [String]
}

private enum UsageProviderSignInError: LocalizedError {
    case failed(String, Int32)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .failed(let provider, let status):
            "\(provider) sign-in did not complete (exit status \(status))."
        case .unavailable(let message):
            message
        }
    }
}
