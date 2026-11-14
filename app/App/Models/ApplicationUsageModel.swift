import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

private struct UsageAnalyticsRefreshKey: Hashable, Sendable {
    let range: String
}

private struct UsageLimitsRefreshKey: Hashable, Sendable {
    let enabledProviders: [String]
    let allowsCredentialAccess: Bool
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
    /// Optional so a service from an earlier build can still answer.
    var usageDevices: [UsageDeviceSummary]?
    var usageHistoryImport: UsageHistoryImportProgress?
}

/// Model prices for the optional API estimate. They are public data, so each
/// process showing Usage loads its own copy instead of asking the backend.
struct UsagePriceState: Equatable {
    var table: UsageRateTable?
    var fetchedAt: Date?
    var isLoading = false
    var error: String?
}

enum BackendUsageCommand: Codable, Sendable {
    case refresh(range: UsageTimeRange, limits: Bool, reason: UsageRefreshReason)
    case analyticsSelected(UsageTimeRange)
    case sharedConnectionsChanged
    case acknowledgeDisclosure
    case authorizeSavedCredentials
    case enable(ProviderKind, UsageTimeRange)
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
    private(set) var usagePrices = UsagePriceState()
    /// This Mac first, then every device with usage or a connection.
    private(set) var usageDevices: [UsageDeviceSummary] = [ApplicationUsageModel.thisDevice]
    /// Set while a full history import is running, so the page can say how far it has got.
    private(set) var usageHistoryImport: UsageHistoryImportProgress?
    /// Lists the devices this Mac can read now. Only the process that owns execution collects.
    @ObservationIgnored
    var usageDeviceEndpoints: (@MainActor () async -> [UsageDeviceEndpoint])?
    @ObservationIgnored
    private var isCollectingDeviceUsage = false
    @ObservationIgnored
    private var lastDeviceCollection: Date?
    @ObservationIgnored
    private var deviceCollectionTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingDeviceRefresh = false
    @ObservationIgnored
    private var lastAnalyticsRange: UsageTimeRange?
    @ObservationIgnored
    private let localUsageService: LocalUsageService
    @ObservationIgnored
    private let usagePriceService: UsagePriceService
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
        // Per-call samples for a busy month exceed the RPC frame. The window only
        // needs them merged per period its graph draws, in the viewer's calendar.
        let projected = localUsage.map {
            LocalUsageSnapshot(analytics: $0.analytics.compactedForDisplay(), limits: $0.limits,
                               hasOpenRouterCredential: $0.hasOpenRouterCredential)
        }
        return BackendUsageSnapshot(localUsage: projected, localUsageError: localUsageError,
            isRefreshingUsageAnalytics: isRefreshingUsageAnalytics, isRefreshingUsageLimits: isRefreshingUsageLimits,
            isAuthorizingUsageCredential: isAuthorizingUsageCredential, isOpenRouterCredentialConfigured: isOpenRouterCredentialConfigured,
            signingInUsageProviders: signingInUsageProviders, hasAcknowledgedCredentialAccessDisclosure: hasAcknowledgedCredentialAccessDisclosure,
            enabledUsageProviders: enabledUsageProviders, usageConnectionChoices: usageConnectionChoices,
            selectedUsageConnections: selectedUsageConnections, usageDevices: usageDevices,
            usageHistoryImport: usageHistoryImport)
    }

    func applyBackendSnapshot(_ value: BackendUsageSnapshot) {
        localUsage = value.localUsage; localUsageError = value.localUsageError
        isRefreshingUsageAnalytics = value.isRefreshingUsageAnalytics; isRefreshingUsageLimits = value.isRefreshingUsageLimits
        isAuthorizingUsageCredential = value.isAuthorizingUsageCredential; isOpenRouterCredentialConfigured = value.isOpenRouterCredentialConfigured
        signingInUsageProviders = value.signingInUsageProviders; hasAcknowledgedCredentialAccessDisclosure = value.hasAcknowledgedCredentialAccessDisclosure
        enabledUsageProviders = value.enabledUsageProviders; usageConnectionChoices = value.usageConnectionChoices
        selectedUsageConnections = value.selectedUsageConnections
        usageDevices = value.usageDevices ?? [Self.thisDevice]
        usageHistoryImport = value.usageHistoryImport
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
        catch BackendRPCError.timedOut {
            // A first full import can outlast one request. The service keeps working
            // and publishes its result, so this is progress rather than a failure.
            await refreshBackendSnapshot()
        } catch { localUsageError = error.localizedDescription }
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
            case let .refresh(range, limits, reason):
                await refreshLocalUsage(range: range, refreshLimits: limits, reason: reason)
            case let .analyticsSelected(range): await usageAnalyticsSelected(range: range)
            case .sharedConnectionsChanged: await sharedConnectionsChanged()
            case .acknowledgeDisclosure: acknowledgeCredentialAccessDisclosure()
            case .authorizeSavedCredentials:
                try await KeychainAccess.$isCredentialAuthorizationActive.withValue(true) {
                    try await authorizeSavedCredentials()
                }
            case let .enable(provider, range): await enableUsageProvider(provider, range: range)
            }
        } else if request.method != "usage.snapshot" { throw BackendRPCError.invalidFrame }
        return try JSONEncoder().encode(backendSnapshot())
    }

    init(
        applicationDefaults: UserDefaults,
        localUsageService: LocalUsageService = LocalUsageService(),
        usagePriceService: UsagePriceService = UsagePriceService()
    ) {
        self.localUsageService = localUsageService
        self.usagePriceService = usagePriceService
        self.applicationDefaults = applicationDefaults
        selectedUsageConnections = applicationDefaults.dictionary(forKey: "wovenmatter.usage.selected-connections") as? [String: String] ?? [:]
        isOpenRouterCredentialConfigured = applicationDefaults.bool(
            forKey: Self.openRouterCredentialConfiguredDefaultsKey
        )
        hasAcknowledgedCredentialAccessDisclosure = applicationDefaults.bool(
            forKey: Self.credentialAccessDisclosureDefaultsKey
        )
        enabledUsageProviders = Set(ProviderKind.supportedAccounts)
    }

    private static let thisDevice = UsageDeviceSummary(
        identity: .init(id: UsageDeviceSource.localDeviceID, name: "This Mac", kind: .mac),
        state: .thisDevice
    )

    /// Keeps every linked device's usage current while the app runs, whether or not Usage is open.
    func startDeviceCollection() {
        guard deviceCollectionTask == nil, !isBackendProjection else { return }
        deviceCollectionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectDeviceUsage(force: true)
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func collectDeviceUsage(force: Bool = false) async {
        guard !isBackendProjection, !isCollectingDeviceUsage, let usageDeviceEndpoints else { return }
        if !force, let lastDeviceCollection, Date().timeIntervalSince(lastDeviceCollection) < 5 * 60 { return }
        isCollectingDeviceUsage = true
        defer { isCollectingDeviceUsage = false }
        lastDeviceCollection = Date()
        let endpoints = await usageDeviceEndpoints()
        let stored = await localUsageService.storedDeviceSummaries()
        var summaries: [String: UsageDeviceSummary] = [:]
        for device in stored {
            summaries[device.identity.id] = .init(identity: device.identity, state: .synced, syncedAt: device.syncedAt)
        }
        for endpoint in endpoints where summaries[endpoint.identity.id] == nil {
            summaries[endpoint.identity.id] = .init(identity: endpoint.identity, state: .waiting)
        }
        publishDevices(summaries)
        var received = false
        for endpoint in endpoints {
            let result = await localUsageService.collectDeviceUsage(from: endpoint)
            summaries[endpoint.identity.id] = result
            received = received || result.state == .synced
            // A Mac may have passed on remote workspaces, which appear as their own devices.
            for device in await localUsageService.storedDeviceSummaries() where summaries[device.identity.id] == nil {
                summaries[device.identity.id] = .init(identity: device.identity, state: .synced, syncedAt: device.syncedAt)
            }
            publishDevices(summaries)
        }
        guard received else { return }
        if isRefreshingUsageAnalytics {
            pendingDeviceRefresh = true
        } else if let lastAnalyticsRange {
            // No transcript scan is needed to show what the devices just reported.
            await refreshUsageAnalytics(range: lastAnalyticsRange, reason: .rangeChanged, policy: .force)
        }
    }

    private func publishDevices(_ summaries: [String: UsageDeviceSummary]) {
        usageDevices = [Self.thisDevice] + summaries.values.sorted {
            $0.identity.name.localizedCaseInsensitiveCompare($1.identity.name) == .orderedAscending
        }
    }

    /// Answers another Mac from the existing index, and refreshes the index
    /// afterward if it's stale, so a long import never holds up that Mac's request.
    func exportDeviceUsage(
        _ request: UsageDeviceExportRequest,
        relaying relayed: [UsageDeviceIdentity]
    ) async throws -> UsageDeviceExportPage {
        if request.offset == 0, !isRefreshingUsageAnalytics, let lastAnalyticsRange {
            Task { await refreshUsageAnalytics(range: lastAnalyticsRange, reason: .periodic, policy: .refresh) }
        }
        return try await localUsageService.deviceExport(request, relaying: relayed)
    }

    /// Runs only when the person asks for API estimates.
    func loadUsagePrices(force: Bool = false) async {
        guard !usagePrices.isLoading else { return }
        usagePrices.isLoading = true
        usagePrices.error = nil
        defer { usagePrices.isLoading = false }
        do {
            let prices = try await usagePriceService.prices(force: force)
            usagePrices.table = prices.table
            usagePrices.fetchedAt = prices.fetchedAt
        } catch {
            usagePrices.error = error.localizedDescription
        }
    }

    func refreshLocalUsage(
        range: UsageTimeRange,
        refreshLimits: Bool = false,
        reason: UsageRefreshReason = .manual
    ) async {
        if isBackendProjection {
            await forward(.refresh(range: range, limits: refreshLimits, reason: reason))
            return
        }
        localUsageError = nil
        prepareUsageSnapshot(range: range)
        if reason == .manual || reason == .viewAppeared {
            Task { await collectDeviceUsage(force: reason == .manual) }
        }
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
            async let analyticsRefresh: Void = refreshUsageAnalytics(
                range: range,
                reason: reason,
                policy: policy
            )
            async let limitsRefresh: Void = refreshUsageLimits(
                reason: reason,
                force: policy == .force
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
        await updateSharedConnectionPresence()
        await refreshLocalUsage(
            range: range,
            refreshLimits: true,
            reason: .viewAppeared
        )
    }
    func sharedConnectionsChanged() async {
        if isBackendProjection { await forward(.sharedConnectionsChanged); return }
        await updateSharedConnectionPresence()
        await refreshLocalUsage(range: currentUsageRange, refreshLimits: true, reason: .credentialChanged)
    }
    private func updateSharedConnectionPresence() async {
        guard !isBackendProjection else { return }
        guard let configured = try? await ProviderConnectionStore.shared.perform(invalidatesAccounts: false, {
            try DefaultAgentSupport.hasKey("openrouter")
        }) else { return }
        guard !Task.isCancelled else { return }
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
        let enabledProviders = Set(ProviderKind.allCases)
        let key = UsageAnalyticsRefreshKey(range: range.rawValue)
        let requestID = UUID()
        lastAnalyticsRange = range
        usageAnalyticsRequestID = requestID
        isRefreshingUsageAnalytics = true
        let onHistoryProgress: @Sendable (UsageHistoryImportProgress, UsageAnalyticsSnapshot?) async -> Void = { [weak self] progress, snapshot in
            let compact = snapshot?.compactedForDisplay()
            await self?.applyHistoryProgress(progress, snapshot: compact, range: range)
        }
        let onHistoryFinished: @Sendable () async -> Void = { [weak self] in
            await self?.finishHistoryImport()
        }
        do {
            let analytics = try await usageAnalyticsRefreshCoordinator.value(
                for: key,
                policy: policy
            ) { [localUsageService] in
                // Only this page reads these samples. Tools read recorded samples separately.
                let analytics = try await localUsageService.analyticsSnapshot(
                    range: range,
                    refreshReason: reason,
                    onHistoryProgress: onHistoryProgress
                )
                await onHistoryFinished()
                return analytics.compactedForDisplay()
            }
            guard usageAnalyticsRequestID == requestID else { return }
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
            if !isRefreshing { usageHistoryImport = nil }
            if !isRefreshing, pendingDeviceRefresh {
                pendingDeviceRefresh = false
                await refreshUsageAnalytics(range: range, reason: .rangeChanged, policy: .force)
            }
        }
    }

    /// Shows each finished batch without waiting for the rest of the history.
    private func applyHistoryProgress(
        _ progress: UsageHistoryImportProgress,
        snapshot: UsageAnalyticsSnapshot?,
        range: UsageTimeRange
    ) {
        guard lastAnalyticsRange == range else { return }
        usageHistoryImport = progress
        guard let snapshot else { return }
        let existing = localUsage
        localUsage = LocalUsageSnapshot(
            analytics: snapshot,
            limits: existing?.limits ?? LocalUsageService.placeholderLimits(enabledProviders: enabledUsageProviders),
            hasOpenRouterCredential: existing?.hasOpenRouterCredential ?? isOpenRouterCredentialConfigured
        )
    }

    private func finishHistoryImport() {
        usageHistoryImport = nil
    }

    private func refreshUsageLimits(
        reason: UsageRefreshReason,
        force: Bool
    ) async {
        let enabledProviders = enabledUsageProviders
        let allowsCredentialAccess = hasAcknowledgedCredentialAccessDisclosure
        let requestedConnections = selectedUsageConnections
        let key = UsageLimitsRefreshKey(
            enabledProviders: enabledProviders.map(\.rawValue).sorted(),
            allowsCredentialAccess: allowsCredentialAccess,
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
                    selectedConnections: requestedConnections
                )
            }
            guard usageLimitsRequestID == requestID,
                  enabledUsageProviders == enabledProviders,
                  selectedUsageConnections == requestedConnections else { return }
            try Task.checkCancellation()
            usageConnectionChoices = limits.connectionChoices
            selectedUsageConnections.merge(limits.selectedConnections) { _, new in new }
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
            reason: .credentialChanged
        )
    }

    private func enableUsageProviderPreference(_ provider: ProviderKind) {
        guard enabledUsageProviders.insert(provider).inserted else { return }
        UsageProviderPreferences(defaults: applicationDefaults).save(
            enabledUsageProviders
        )
    }

}
