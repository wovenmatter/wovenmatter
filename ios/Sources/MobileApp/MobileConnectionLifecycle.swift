import Foundation
import Network
import UIKit
import LibraryClient
import WovenMatterShared

/// Reachability wakes a retry; it is never treated as proof a Mac is reachable.
final class MobileNetworkMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  init(changed: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { changed($0.status == .satisfied) }
    monitor.start(queue: DispatchQueue(label: "com.wovenmatter.wovenmatter.reachability"))
  }
  func cancel() { monitor.cancel() }
  deinit { monitor.cancel() }
}

extension MobileModel {
  var deviceMetadata: DeviceMetadata {
    .init(kind: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
      osVersion: UIDevice.current.systemVersion,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
  }

  func acceptPairing(_ paired: MobileCredential, allowingLibraryChange: Bool = false, keepLibrary: Bool = false,
                     saveCredential: (MobileCredential) throws -> Void) async throws {
    guard let store else { throw MobileConnectionError.invalidResponse }
    let connection = try HTTPSLibraryTransport(credential: paired, metadata: deviceMetadata, performer: httpPerformer)
    connectionGeneration = UUID()
    connectionRefreshTask?.cancel(); connectionRefreshTask = nil
    for task in workspaceReadTasks.values { task.cancel() }
    workspaceReadTasks = [:]
    closeWorkspaceStreams()
    let previousEngine = engine
    credential = nil; transport = nil; engine = nil; online = false
    await previousEngine?.cancelSynchronization()
    let committed = try await MobilePairingCommit.complete(paired, store: store,
      allowingLibraryChange: allowingLibraryChange, keepLibrary: keepLibrary, saveCredential: saveCredential,
      confirm: { try await pairingRequests(connection).confirmPairing() })
    // The pairing connection only confirms the pairing (and unpairs);
    // `completeMemberPairing` then signs every request, or nothing syncs.
    credential = committed; transport = connection
    synchronizationStatus = .init(); online = false; connectionLabel = "Connecting"
    centralRetryCount = 0; centralRefreshAfter = .distantPast; centralProvidersRefreshDue = true
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
    for task in workspaceReadTasks.values { task.cancel() }
    workspaceReadTasks = [:]
    closeWorkspaceStreams()
    let previousEngine = engine
    let previousTransport = transport
    credential = nil; transport = nil; engine = nil
    online = false; connecting = false; connectionLabel = "Disconnected"
    let workspaceIDs = Set(workspaceClients.keys).union(executionWorkspaces.map(\.id))
    workspaceClients = [:]; workspaceProviders = [:]; workspaceReachable = [:]
    remotePending = [:]; pending = []; providers = []
    await previousEngine?.cancelSynchronization()
    do {
      // Best effort while reachable; local unpairing also works offline.
      if let previousTransport { try? await pairingRequests(previousTransport).unpair() }
      try clearCredential()
      clearMembership()
      try await store?.recoverPairingTransition()
      try await store?.detachWorkspace()
      let journalIDs = await store?.journal.snapshot().workspaces.keys.map { $0 } ?? []
      for id in workspaceIDs.union(journalIDs) where id != deviceWorkspaceID {
        try clearWorkspaceCredential(id)
      }
      pairingError = nil
      await reload()
    } catch { pairingError = error.localizedDescription }
  }

  /// The foreground library sync cadence while the library host's stream does
  /// not announce its changes (no stream, an older host, or the stream is
  /// down). It reads no execution workspace. While that stream carries
  /// `library` items there is no timer: each item ahead of this phone's
  /// cursor synchronizes at once.
  static let librarySyncInterval: Duration = .seconds(15)

  /// How the foreground loop waits between library passes.
  enum LibrarySyncPause: Equatable { case none, timer, stream }

  /// Whether the library needs the 15 s timer: the library host this phone
  /// syncs with does not announce its changes on an open stream.
  var librarySyncTimerNeeded: Bool {
    guard let libraryStream, let host = libraryHostDeviceID?.lowercased() else { return true }
    return libraryStream.deviceID != host
  }

  /// A `library` item from a workspace's stream: the server's library change
  /// cursor. From the library host this phone syncs with, it replaces the
  /// timer, and a cursor other than the one this phone holds synchronizes
  /// now: ahead (a change), or behind (the host's library was restored or
  /// reset, which only a sync can tell this phone).
  /// Cursors of other servers are not comparable with this phone's and are
  /// ignored (their changes reach the host by peer sync, which announces them).
  func libraryChanged(cursor: Int64, serverDeviceID: String, workspaceID: String) async {
    guard let host = libraryHostDeviceID?.lowercased(), host == serverDeviceID.lowercased() else {
      if libraryStream?.workspaceID == workspaceID { setLibraryStream(nil) }
      return
    }
    setLibraryStream((workspaceID, host))
    guard let store, cursor != (await store.snapshot().cursor) else { return }
    synchronizeLibraryNow()
  }

  /// One library pass at once, then the registry's streams reconciled. A
  /// pass already running runs once more afterwards (`refresh`).
  func synchronizeLibraryNow() {
    guard automaticSynchronization, !fixture, !isolatedTestHost, connectionForeground else { return }
    Task { [weak self] in
      guard let self else { return }
      await self.refresh()
      await self.refreshExecutionWorkspaces()
    }
  }

  /// The stream that announces the library host's changes, or nil. A change
  /// wakes the foreground loop, which starts or stops its timer.
  func setLibraryStream(_ value: (workspaceID: String, deviceID: String)?) {
    guard libraryStream?.workspaceID != value?.workspaceID || libraryStream?.deviceID != value?.deviceID else { return }
    libraryStream = value
    libraryStreamChanged()
  }

  /// Wakes the loop when its pause no longer fits: a timer that is no longer
  /// needed, or a wait for a stream that no longer announces changes.
  func libraryStreamChanged() {
    let tick = librarySyncTimerNeeded || liveViewFallbackNeeded
    switch librarySyncPause {
    case .timer where !tick, .stream where tick: wakeLibrarySyncLoop()
    default: break
    }
  }

  func wakeLibrarySyncLoop() {
    librarySyncTimeout?.cancel(); librarySyncTimeout = nil
    let waiter = librarySyncWake; librarySyncWake = nil
    waiter?.resume()
  }

  /// Waits for `timeout`, or with none until the library stream changes.
  private func pauseLibrarySync(_ pause: LibrarySyncPause, timeout: Duration?) async {
    guard !Task.isCancelled else { return }
    librarySyncPause = pause
    defer { librarySyncPause = .none }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        librarySyncWake = continuation
        if let timeout {
          librarySyncTimeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.wakeLibrarySyncLoop()
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.wakeLibrarySyncLoop() }
    }
  }

  static func connectionRetryDelay(_ failures: Int) -> TimeInterval {
    min(120, 5 * pow(2, Double(min(max(failures - 1, 0), 5))))
  }

  func connectionDidBecomeActive() {
    connectionForeground = true
    // Every stream reconnects now, before the library sync below finishes.
    resumeWorkspaceStreams()
    guard automaticSynchronization, !fixture, !isolatedTestHost else { return }
    centralRefreshAfter = .distantPast; centralProvidersRefreshDue = true
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
    defer { networkMonitor?.cancel(); networkMonitor = nil; connectionRefreshTask?.cancel(); wakeLibrarySyncLoop() }
    var first = true
    while !Task.isCancelled {
      // One pass when the loop starts; after that only on the timer.
      if connectionForeground, first || librarySyncTimerNeeded {
        if Date() >= centralRefreshAfter { await refresh() }
        await refreshExecutionWorkspaces()
        if let engine { synchronizationStatus = await engine.synchronizationStatus() }
      }
      // A live view no connected stream carries: the open chat and its questions.
      if connectionForeground, !first { await refreshLiveViewsWithoutStream() }
      first = false
      // Library sync (notes, calendar, dictation, artifacts and the
      // registry) every 15 s, unless the library host's stream announces its
      // changes: then each `library` item whose cursor differs from this
      // phone's synchronizes at once. Live views of sessions stream; the
      // same tick reads one only while no connected stream carries it.
      if librarySyncTimerNeeded || liveViewFallbackNeeded { await pauseLibrarySync(.timer, timeout: Self.librarySyncInterval) }
      else { await pauseLibrarySync(.stream, timeout: nil) }
    }
  }

  func connectionDidBecomeReachable() {
    guard connectionForeground else { return }
    reconnectWorkspaceStreams()
    centralRefreshAfter = .distantPast; centralProvidersRefreshDue = true
    requestSynchronization(immediately: true)
  }

  var pendingSyncCount: Int { synchronizationStatus.lanes.values.reduce(0) { $0 + $1.pendingCount } }
}
