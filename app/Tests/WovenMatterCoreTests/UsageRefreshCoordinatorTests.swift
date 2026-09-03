import Foundation
import Testing
@testable import WovenMatterDashboardStore

@Suite("Usage analytics refresh lifecycle", .serialized)
struct UsageRefreshCoordinatorTests {
  @Test("entering Usage on Limits starts Analytics loading")
  func appearanceStartsAnalyticsLoading() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let loader = SuspendingUsageLoader()
    let refresh = Task {
      try await coordinator.value(for: "30-days", policy: .refresh) {
        try await loader.load()
      }
    }

    await loader.waitForStarts(1)
    #expect(await loader.startCount == 1)
    #expect(await coordinator.isRefreshing)
    await loader.release()
    #expect(try await refresh.value == 1)
  }

  @Test("selecting Analytics during prefetch reuses the in-flight refresh")
  func selectionCoalescesWithPrefetch() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let loader = SuspendingUsageLoader()
    let prefetch = Task {
      try await coordinator.value(for: "30-days", policy: .refresh) {
        try await loader.load()
      }
    }
    await loader.waitForStarts(1)
    let selection = Task {
      try await coordinator.value(for: "30-days", policy: .reuse) {
        try await loader.load()
      }
    }

    await loader.release()
    #expect(try await prefetch.value == 1)
    #expect(try await selection.value == 1)
    #expect(await loader.startCount == 1)
  }

  @Test("repeated Usage tab switching does not duplicate Analytics refreshes")
  func repeatedSelectionReusesCompletedPrefetch() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let loader = ImmediateUsageLoader()
    let prefetched = try await coordinator.value(for: "30-days", policy: .refresh) {
      await loader.load()
    }
    #expect(prefetched == 1)

    for _ in 0..<6 {
      let reused = try await coordinator.value(for: "30-days", policy: .reuse) {
        await loader.load()
      }
      #expect(reused == 1)
    }
    #expect(await loader.startCount == 1)
  }

  @Test("manual refresh forces a new Analytics refresh")
  func manualRefreshForcesRefresh() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let loader = ImmediateUsageLoader()
    _ = try await coordinator.value(for: "30-days", policy: .refresh) {
      await loader.load()
    }
    let refreshed = try await coordinator.value(for: "30-days", policy: .force) {
      await loader.load()
    }

    #expect(refreshed == 2)
    #expect(await loader.startCount == 2)
  }

  @Test("failed or cancelled prefetch permits a later retry")
  func failureAndCancellationPermitRetry() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let failingLoader = FailingUsageLoader()
    await #expect(throws: UsageLoaderFailure.self) {
      try await coordinator.value(for: "30-days", policy: .refresh) {
        try await failingLoader.load()
      }
    }
    let retry = try await coordinator.value(for: "30-days", policy: .reuse) {
      try await failingLoader.load()
    }
    #expect(retry == 2)

    let cancellationCoordinator = UsageRefreshCoordinator<String, Int>()
    let suspendingLoader = SuspendingUsageLoader()
    let cancelled = Task {
      try await cancellationCoordinator.value(for: "90-days", policy: .refresh) {
        try await suspendingLoader.load()
      }
    }
    await suspendingLoader.waitForStarts(1)
    await cancellationCoordinator.cancelCurrent()
    await suspendingLoader.release()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }

    let retried = Task {
      try await cancellationCoordinator.value(for: "90-days", policy: .reuse) {
        try await suspendingLoader.load()
      }
    }
    await suspendingLoader.waitForStarts(2)
    await suspendingLoader.release()
    #expect(try await retried.value == 2)
  }
}

private actor ImmediateUsageLoader {
  private(set) var startCount = 0

  func load() -> Int {
    startCount += 1
    return startCount
  }
}

private actor FailingUsageLoader {
  private(set) var startCount = 0

  func load() throws -> Int {
    startCount += 1
    if startCount == 1 { throw UsageLoaderFailure() }
    return startCount
  }
}

private struct UsageLoaderFailure: Error {}

private actor SuspendingUsageLoader {
  private(set) var startCount = 0
  private var permits = 0
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func load() async throws -> Int {
    startCount += 1
    let invocation = startCount
    let ready = startWaiters.filter { invocation >= $0.0 }
    startWaiters.removeAll { invocation >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { continuation in
      if permits > 0 {
        permits -= 1
        continuation.resume()
      } else {
        loadContinuation = continuation
      }
    }
    try Task.checkCancellation()
    return invocation
  }

  func waitForStarts(_ expected: Int) async {
    guard startCount < expected else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((expected, continuation))
    }
  }

  func release() {
    if let loadContinuation {
      self.loadContinuation = nil
      loadContinuation.resume()
    } else {
      permits += 1
    }
  }
}
