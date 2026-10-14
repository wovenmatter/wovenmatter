import Foundation
import Network
import UIKit
import CompanionClient
import WovenMatterCompanion

/// Reachability wakes a retry; it is never treated as proof a Mac is reachable.
final class MobileNetworkMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  init(changed: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { changed($0.status == .satisfied) }
    monitor.start(queue: DispatchQueue(label: "com.wovenmatter.companion.reachability"))
  }
  func cancel() { monitor.cancel() }
  deinit { monitor.cancel() }
}

extension CompanionModel {
  var deviceMetadata: CompanionDeviceMetadata {
    .init(kind: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
      osVersion: UIDevice.current.systemVersion,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
  }

  /// Keep the library binding even if the user disconnects before the initial
  /// snapshot completes. Pairing another central database must never merge it.
  func acceptPairing(_ paired: MobileCredential,
                     saveCredential: (MobileCredential) throws -> Void) async throws {
    guard let store else { throw MobileConnectionError.invalidResponse }
    let current = await store.snapshot()
    guard paired.deviceID == current.deviceID else { throw MobileConnectionError.invalidResponse }
    try await store.verifyWorkspace(paired.workspaceID)
    let connection = try HTTPSCompanionTransport(credential: paired, metadata: deviceMetadata)
    try await store.bindWorkspace(paired.workspaceID)
    try saveCredential(paired)
    connectionGeneration = UUID()
    await engine?.cancelSynchronization()
    credential = paired; transport = connection
    engine = MobileSyncEngine(store: store, transport: connection)
    synchronizationStatus = .init(); online = false; connectionLabel = "Connecting"
    centralRetryCount = 0; centralRefreshAfter = .distantPast
    pairingError = nil
    await reload()
    try await ensureDeviceWorkspace()
  }

  func disconnectMac(clearCredential: () throws -> Void = MobileCredentialVault.clear,
                     clearWorkspaceCredential: (String) throws -> Void = WorkspaceCredentialVault.clear) async {
    guard !pairingInProgress else { return }
    pairingInProgress = true
    defer { pairingInProgress = false }
    connectionGeneration = UUID()
    connectionRefreshTask?.cancel(); connectionRefreshTask = nil
    for task in workspacePollTasks.values { task.cancel() }
    workspacePollTasks = [:]
    let previousEngine = engine
    credential = nil; transport = nil; engine = nil
    online = false; connecting = false; connectionLabel = "Disconnected"
    let workspaceIDs = Set(workspaceClients.keys).union(executionWorkspaces.map(\.id))
    workspaceClients = [:]; workspaceProviders = [:]; workspaceReachable = [:]
    remotePending = [:]; pending = []; providers = []
    await previousEngine?.cancelSynchronization()
    do {
      // Do not touch inference credentials, content, outboxes, or the library
      // binding. Only explicit unpairing drops the central-issued access grants.
      try clearCredential()
      let journalIDs = await store?.journal.snapshot().workspaces.keys.map { $0 } ?? []
      for id in workspaceIDs.union(journalIDs) where id != deviceWorkspaceID {
        try clearWorkspaceCredential(id)
      }
      pairingError = nil
      await reload()
    } catch { pairingError = error.localizedDescription }
  }

  static func connectionRetryDelay(_ failures: Int) -> TimeInterval {
    min(120, 5 * pow(2, Double(min(max(failures - 1, 0), 5))))
  }

  func connectionDidBecomeActive() {
    connectionForeground = true
    guard automaticSynchronization, !fixture, !isolatedTestHost else { return }
    centralRefreshAfter = .distantPast; workspaceRefreshAfter = [:]
    requestSynchronization(immediately: true)
  }

  func requestSynchronization(immediately: Bool = false) {
    guard automaticSynchronization, !fixture, !isolatedTestHost, connectionForeground else { return }
    connectionRefreshTask?.cancel()
    connectionRefreshTask = Task { [weak self] in
      if !immediately { try? await Task.sleep(for: .milliseconds(500)) }
      guard let self, !Task.isCancelled, self.connectionForeground else { return }
      // Edits coalesce promptly; an unavailable central gets bounded retries.
      if immediately || self.online || Date() >= self.centralRefreshAfter { await self.refresh() }
      guard !Task.isCancelled else { return }
      await self.refreshExecutionWorkspaces(force: immediately)
    }
  }

  func maintainConnections() async {
    guard !fixture else { return }
    networkMonitor = MobileNetworkMonitor { [weak self] reachable in
      guard reachable else { return }
      Task { @MainActor [weak self] in self?.connectionDidBecomeReachable() }
    }
    defer { networkMonitor?.cancel(); networkMonitor = nil; connectionRefreshTask?.cancel() }
    while !Task.isCancelled {
      if connectionForeground {
        if Date() >= centralRefreshAfter { await refresh() }
        await refreshExecutionWorkspaces()
        if let engine { synchronizationStatus = await engine.synchronizationStatus() }
      }
      // A viewed running chat receives live activity. Idle workspaces and failed
      // connections each have their own longer deadline before any network work.
      let interval: Duration = tab == .chat && activeRunID != nil ? .seconds(2) : .seconds(15)
      do { try await Task.sleep(for: interval) } catch { return }
    }
  }

  private func connectionDidBecomeReachable() {
    guard connectionForeground else { return }
    centralRefreshAfter = .distantPast; workspaceRefreshAfter = [:]
    requestSynchronization(immediately: true)
  }

  var pendingSyncCount: Int { synchronizationStatus.lanes.values.reduce(0) { $0 + $1.pendingCount } }
  var syncConflictCount: Int { synchronizationStatus.lanes.values.reduce(0) { $0 + $1.conflictCount } }
  var hasPendingRecovery: Bool {
    !state.conflicts.isEmpty || syncConflictCount > 0 || !unresolvedCommands.isEmpty || state.launches.contains { !$0.accepted }
  }
}
