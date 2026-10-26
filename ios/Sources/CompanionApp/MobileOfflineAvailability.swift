import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  func refreshSynchronizationStatus() async {
    if let engine { synchronizationStatus = await engine.synchronizationStatus(); return }
    guard let store else { return }
    let snapshot = await store.snapshot()
    let journal = await store.journal.pendingOwnerEntries(deviceID: snapshot.deviceID)
    let counts: [MobileSyncLane: Int] = [.dictation: (try? await store.dictations.pendingCount()) ?? 0, .library: snapshot.outbox.count,
      .calendar: await store.calendar.pendingCount() + store.calendar.pendingRuns().count,
      .journal: journal.count, .artifacts: await store.artifacts.pendingUploadCount(),
      .offlineCache: snapshot.uncachedNoteIDs.count + (await store.artifacts.pendingDownloadCount())]
    for lane in MobileSyncLane.allCases {
      var status = synchronizationStatus.lanes[lane] ?? .init()
      status.pendingCount = counts[lane] ?? 0
      status.conflictCount = lane == .library ? snapshot.conflicts.count : lane == .calendar ? await store.calendar.conflicts().count : 0
      status.phase = status.conflictCount > 0 ? .blocked : status.pendingCount > 0 ? .pending : status.lastSuccessfulSync == nil ? .idle : .current
      synchronizationStatus.lanes[lane] = status
    }
  }

  func downloadOfflineConversation(_ id: String) async throws {
    let owner = executionOwner(of: id)
    if owner == "local" { return } // Native checkpoint/history already lives here.
    if owner == "central" {
      guard let engine, online else { return } // The durable pin retries on reconnect.
      try await engine.keepTranscriptOffline(id)
    } else if workspaceReachable[owner] == true, let client = workspaceClients[owner], let store {
      _ = try await client.refreshTranscript(id)
      var visited = Set<String>()
      while let before = await store.snapshot().transcripts[id]?.olderCursor, visited.insert(before).inserted {
        try Task.checkCancellation()
        let page = try await client.earlierTranscript(id, before: before)
        try await store.cacheTranscriptPage(page)
      }
    }
  }

  func artifactURL(_ id: String) async throws -> URL {
    if let url = await store?.artifacts.localURL(id: id) { return url }
    guard let engine, online else { throw DeviceExecutionError.unavailable("Connect to the central database to download this artifact.") }
    return try await engine.ensureArtifactCached(id)
  }

}
