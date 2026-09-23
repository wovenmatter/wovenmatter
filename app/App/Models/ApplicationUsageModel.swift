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
    let selectedConnections: [String: String]
}

struct BackendUsageSnapshot: Codable, Sendable {
    var localUsage: LocalUsageSnapshot?
    var localUsageError: String?
    var isRefreshingUsageAnalytics: Bool
    var isRefreshingUsageLimits: Bool
    var isAuthorizingUsageCredential: Bool
    var isOpenRouterCredentialConfigured: Bool
    var signingInUsageProviders: Set<ProviderKind>
    var hasAcknowledgedCredentialAccessDisclosure: Bool
    var enabledUsageProviders: Set<ProviderKind>
    var usageConnectionChoices: [UsageConnectionChoice]
    var selectedUsageConnections: [String: String]
    var codexUsageWorkspaces: [CodexUsageWorkspace]
    var selectedCodexUsageWorkspaceID: String?
}

enum BackendUsageCommand: Codable, Sendable {
    case refresh(range: UsageTimeRange, limits: Bool, reason: UsageRefreshReason, explicit: Bool, provider: ProviderKind?)
    case analyticsSelected(UsageTimeRange)
    case sharedConnectionsChanged
    case saveOpenRouterKey(String, UsageTimeRange)
    case deleteOpenRouterKey(UsageTimeRange)
    case acknowledgeDisclosure
    case authorizeSavedCredentials
    case enable(ProviderKind, UsageTimeRange)
    case retry(ProviderKind, UsageTimeRange)
    case selectConnection(String, ProviderKind, UsageTimeRange)
    case selectWorkspace(String, UsageTimeRange)
    case disable(ProviderKind, UsageTimeRange)
    case signIn(ProviderKind)
    case reconnectWorkspace
}

private struct BackendUsageSamplesRequest: Codable {
    let start: Date
    let end: Date
    let limit: Int
    let offset: Int
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
    private(set) var usageConnectionChoices: [UsageConnectionChoice] = []
    private(set) var selectedUsageConnections: [String: String] = [:]
    private(set) var codexUsageWorkspaces: [CodexUsageWorkspace] = []
    private(set) var selectedCodexUsageWorkspaceID: String?
    @ObservationIgnored
    private lazy var localUsageService = LocalUsageService()
    @ObservationIgnored
    var backendRequest: (@MainActor (String, Data) async throws -> Data)?
    @ObservationIgnored
    private var backendGeneration = UUID()
    @ObservationIgnored
    var isBackendProjection = LocalExecutionRole.current == .frontend
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
        if isBackendProjection {
            guard let backendRequest else { throw BackendRPCError.unavailable }
            let payload = try JSONEncoder().encode(BackendUsageSamplesRequest(start: start, end: end, limit: limit, offset: offset))
            return try JSONDecoder().decode([UsageSample].self, from: await backendRequest("usage.samples", payload))
        }
        return try await localUsageService.recordedSamples(from: start, to: end, limit: limit, offset: offset)
    }

    func backendSnapshot() -> BackendUsageSnapshot {
        BackendUsageSnapshot(localUsage: localUsage, localUsageError: localUsageError,
            isRefreshingUsageAnalytics: isRefreshingUsageAnalytics, isRefreshingUsageLimits: isRefreshingUsageLimits,
            isAuthorizingUsageCredential: isAuthorizingUsageCredential, isOpenRouterCredentialConfigured: isOpenRouterCredentialConfigured,
            signingInUsageProviders: signingInUsageProviders, hasAcknowledgedCredentialAccessDisclosure: hasAcknowledgedCredentialAccessDisclosure,
            enabledUsageProviders: enabledUsageProviders, usageConnectionChoices: usageConnectionChoices,
            selectedUsageConnections: selectedUsageConnections, codexUsageWorkspaces: codexUsageWorkspaces,
            selectedCodexUsageWorkspaceID: selectedCodexUsageWorkspaceID)
    }

    func applyBackendSnapshot(_ value: BackendUsageSnapshot) {
        localUsage = value.localUsage; localUsageError = value.localUsageError
        isRefreshingUsageAnalytics = value.isRefreshingUsageAnalytics; isRefreshingUsageLimits = value.isRefreshingUsageLimits
        isAuthorizingUsageCredential = value.isAuthorizingUsageCredential; isOpenRouterCredentialConfigured = value.isOpenRouterCredentialConfigured
        signingInUsageProviders = value.signingInUsageProviders; hasAcknowledgedCredentialAccessDisclosure = value.hasAcknowledgedCredentialAccessDisclosure
        enabledUsageProviders = value.enabledUsageProviders; usageConnectionChoices = value.usageConnectionChoices
        selectedUsageConnections = value.selectedUsageConnections; codexUsageWorkspaces = value.codexUsageWorkspaces
        selectedCodexUsageWorkspaceID = value.selectedCodexUsageWorkspaceID
    }

    func refreshBackendSnapshot() async {
        guard isBackendProjection else { return }
        let generation = backendGeneration
        do {
            guard let backendRequest else { throw BackendRPCError.unavailable }
            let data = try await backendRequest("usage.snapshot", Data())
            guard generation == backendGeneration else { return }
            applyBackendSnapshot(try JSONDecoder().decode(BackendUsageSnapshot.self, from: data))
        } catch { if generation == backendGeneration { localUsageError = error.localizedDescription } }
    }

    private func forward(_ command: BackendUsageCommand) async {
        do { try await forwardThrowing(command) }
        catch { localUsageError = error.localizedDescription }
    }

    private func forwardThrowing(_ command: BackendUsageCommand) async throws {
        guard let backendRequest else { throw BackendRPCError.unavailable }
        let generation = UUID(); backendGeneration = generation
        let data = try await backendRequest("usage.command", JSONEncoder().encode(command))
        guard generation == backendGeneration else { return }
        applyBackendSnapshot(try JSONDecoder().decode(BackendUsageSnapshot.self, from: data))
    }

    func handleBackendRequest(_ request: BackendRPCRequest) async throws -> Data {
        guard !isBackendProjection else { throw BackendRPCError.unavailable }
        if request.method == "usage.samples" {
            let value = try JSONDecoder().decode(BackendUsageSamplesRequest.self, from: request.payload)
            return try JSONEncoder().encode(await recordedUsageSamples(from: value.start, to: value.end, limit: value.limit, offset: value.offset))
        }
        if request.method == "usage.command" {
            switch try JSONDecoder().decode(BackendUsageCommand.self, from: request.payload) {
            case let .refresh(range, limits, reason, explicit, provider):
                await refreshLocalUsage(range: range, refreshLimits: limits, reason: reason, explicitCredentialAccess: explicit, interactiveProvider: provider)
            case let .analyticsSelected(range): await usageAnalyticsSelected(range: range)
            case .sharedConnectionsChanged: await sharedConnectionsChanged()
            case let .saveOpenRouterKey(value, range): await saveOpenRouterAPIKey(value, range: range)
            case let .deleteOpenRouterKey(range): await deleteOpenRouterAPIKey(range: range)
            case .acknowledgeDisclosure: acknowledgeCredentialAccessDisclosure()
            case .authorizeSavedCredentials: try await authorizeSavedCredentials()
            case let .enable(provider, range): await enableUsageProvider(provider, range: range)
            case let .retry(provider, range): await retryUsageProviderCredentialAccess(provider, range: range)
            case let .selectConnection(id, provider, range): await selectUsageConnection(id, provider: provider, range: range)
            case let .selectWorkspace(id, range): await selectCodexUsageWorkspace(id, range: range)
            case let .disable(provider, range): await disableUsageProvider(provider, range: range)
            case let .signIn(provider): signInUsageProvider(provider)
            case .reconnectWorkspace: reconnectSelectedCodexUsageWorkspace()
            }
        } else if request.method != "usage.snapshot" { throw BackendRPCError.invalidFrame }
        return try JSONEncoder().encode(backendSnapshot())
    }

    init(applicationDefaults: UserDefaults) {
        self.applicationDefaults = applicationDefaults
        selectedUsageConnections = applicationDefaults.dictionary(forKey: "wovenmatter.usage.selected-connections") as? [String: String] ?? [:]
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
        if isBackendProjection {
            await forward(.refresh(range: range, limits: refreshLimits, reason: reason, explicit: explicitCredentialAccess, provider: interactiveProvider))
            return
        }
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
        if isBackendProjection { await forward(.sharedConnectionsChanged); return }
        updateSharedConnectionPresence()
        await refreshLocalUsage(range: currentUsageRange, refreshLimits: true, reason: .credentialChanged)
    }
    private func updateSharedConnectionPresence() {
        guard !isBackendProjection else { return }
        guard let configured = try? DefaultAgentSupport.hasKey("openrouter") else { return }
        isOpenRouterCredentialConfigured = configured
        applicationDefaults.set(configured, forKey: Self.openRouterCredentialConfiguredDefaultsKey)
    }

    func usageAnalyticsSelected(range: UsageTimeRange) async {
        if isBackendProjection { await forward(.analyticsSelected(range)); return }
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
        let allowsCredentialAccess = hasAcknowledgedCredentialAccessDisclosure
        let requestedConnections = selectedUsageConnections
        let requestedCodexWorkspaceID = selectedCodexUsageWorkspaceID
        let key = UsageLimitsRefreshKey(
            enabledProviders: enabledProviders.map(\.rawValue).sorted(),
            allowsCredentialAccess: allowsCredentialAccess,
            keychainInteraction: keychainInteraction.rawValue,
            interactiveProvider: interactiveProvider?.rawValue,
            selectedCodexWorkspaceID: requestedCodexWorkspaceID,
            selectedConnections: requestedConnections
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
                    selectedCodexWorkspaceID: requestedCodexWorkspaceID,
                    selectedConnections: requestedConnections
                )
            }
            guard usageLimitsRequestID == requestID,
                  enabledUsageProviders == enabledProviders,
                  selectedUsageConnections == requestedConnections,
                  selectedCodexUsageWorkspaceID == requestedCodexWorkspaceID else { return }
            try Task.checkCancellation()
            usageConnectionChoices = limits.connectionChoices
            selectedUsageConnections.merge(limits.selectedConnections) { _, new in new }
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
        if isBackendProjection { await forward(.saveOpenRouterKey(value, range)); return }
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
        if isBackendProjection { await forward(.deleteOpenRouterKey(range)); return }
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
        if isBackendProjection {
            hasAcknowledgedCredentialAccessDisclosure = true
            Task { await forward(.acknowledgeDisclosure) }
            return
        }
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
        if isBackendProjection { try await forwardThrowing(.authorizeSavedCredentials); return }
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
        if isBackendProjection { await forward(.enable(provider, range)); return }
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
        if isBackendProjection { await forward(.retry(provider, range)); return }
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

    func selectUsageConnection(_ id: String, provider: ProviderKind, range: UsageTimeRange) async {
        if isBackendProjection { await forward(.selectConnection(id, provider, range)); return }
        guard enabledUsageProviders.contains(provider),
              usageConnectionChoices.contains(where: { $0.provider == provider && $0.id == id }),
              selectedUsageConnections[provider.rawValue] != id else { return }
        selectedUsageConnections[provider.rawValue] = id
        applicationDefaults.set(selectedUsageConnections, forKey: "wovenmatter.usage.selected-connections")
        // Remove the old account's numbers immediately, before any asynchronous
        // request can leave them displayed under the newly selected identity.
        if let current = localUsage {
            localUsage = LocalUsageSnapshot(analytics: current.analytics,
                limits: current.limits.filter { $0.provider != provider },
                hasOpenRouterCredential: current.hasOpenRouterCredential)
        }
        await refreshUsageLimits(reason: .credentialChanged, force: true,
            keychainInteraction: .noninteractive, interactiveProvider: nil)
    }

    func selectCodexUsageWorkspace(
        _ workspaceID: String,
        range: UsageTimeRange
    ) async {
        if isBackendProjection { await forward(.selectWorkspace(workspaceID, range)); return }
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
        if isBackendProjection { await forward(.disable(provider, range)); return }
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
        if isBackendProjection {
            if [.codex, .claude, .grok, .openRouter, .openCodeGo].contains(provider) {
                NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: "global")
            } else { Task { await forward(.signIn(provider)) } }
            return
        }
        if [.codex, .claude, .grok, .openRouter, .openCodeGo].contains(provider) {
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
        if isBackendProjection { Task { await forward(.reconnectWorkspace) }; return }
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
