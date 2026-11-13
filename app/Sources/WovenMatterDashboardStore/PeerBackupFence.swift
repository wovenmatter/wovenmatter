import Foundation
import WovenMatterCore

/// The one-time recovery backup that precedes a library's first peer import
/// (`Paired Mac Backups/before-peer-sync.sqlite`), one per backup file in
/// this process and shared by every handle on that database.
///
/// The copy reads its own connection on its own queue, never a worker lane:
/// a multi-gigabyte library takes minutes to copy and verify, and every other
/// database job keeps its normal 30-second bound meanwhile. Nothing in pairing
/// waits for it. Only peer imports do: once armed, the library accepts no
/// peer page until the backup exists, which keeps the backup a copy of the
/// library from before pairing.
///
/// Arming is durable: a marker file beside the backup keeps imports fenced
/// after a quit or crash interrupts the copy, until a later copy finishes.
/// A failed copy is not retried at once, since the usual cause (too little
/// free space for a second copy of the library) persists: retries wait one
/// minute, doubling to fifteen, and waiters meanwhile get the last error.
final class PeerBackupFence: @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [String: PeerBackupFence] = [:]

  /// The fence for `file`. Fences are never released, so closing and
  /// reopening every handle mid-copy can never start a second copy.
  static func shared(for file: URL) -> PeerBackupFence {
    let key = file.standardizedFileURL.path
    return registryLock.withLock {
      if let fence = registry[key] { return fence }
      let fence = PeerBackupFence(file: file)
      registry[key] = fence
      return fence
    }
  }

  let file: URL
  private let lock = NSLock()
  /// The first synchronization waits for this copy, so it runs at the database
  /// lanes' QoS: a utility queue has its disk reads throttled under load.
  private let queue = DispatchQueue(label: "wovenmatter.database.peer-backup", qos: DispatchQoS(qosClass: PortablePOSIX.waitedOnQoS, relativePriority: 0))
  private let minimumRetryDelay: TimeInterval
  private let maximumRetryDelay: TimeInterval
  private let now: @Sendable () -> Date
  private var armed = false
  private var running = false
  private var failure: (any Error)?
  private var failures = 0
  private var retryAfter = Date.distantPast
  private var waiters: [UUID: CheckedContinuation<Bool, any Error>] = [:]

  init(file: URL, minimumRetryDelay: TimeInterval = 60, maximumRetryDelay: TimeInterval = 15 * 60,
       now: @escaping @Sendable () -> Date = { Date() }) {
    self.file = file
    self.minimumRetryDelay = minimumRetryDelay
    self.maximumRetryDelay = maximumRetryDelay
    self.now = now
  }

  /// Present while this library requires a backup it may not have yet.
  var marker: URL { file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".required") }

  private var backupExists: Bool { FileManager.default.fileExists(atPath: file.path) }

  /// Imports may proceed: the fence was never armed, or the backup exists.
  var isOpen: Bool {
    if backupExists { return true }
    return !lock.withLock { armed } && !FileManager.default.fileExists(atPath: marker.path)
  }

  /// Arms the fence and starts `backup` unless it is running, done, or
  /// waiting out the retry delay after a failure.
  func start(_ backup: @escaping @Sendable () throws -> Void) {
    let arming = lock.withLock { () -> Bool in defer { armed = true }; return !armed }
    if arming, !backupExists {
      // Best effort: without the marker the fence still holds in memory.
      try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    let begin: Bool = lock.withLock {
      guard !running, !backupExists, now() >= retryAfter else { return false }
      running = true; failure = nil
      return true
    }
    guard begin else { return }
    queue.async {
      let result = Result { try backup() }
      let waiting: [CheckedContinuation<Bool, any Error>] = self.lock.withLock {
        self.running = false
        switch result {
        case .success:
          self.failures = 0; self.retryAfter = .distantPast
        case .failure(let error):
          self.failure = error; self.failures += 1
          let delay = min(self.maximumRetryDelay, self.minimumRetryDelay * pow(2, Double(min(self.failures - 1, 16))))
          self.retryAfter = self.now().addingTimeInterval(delay)
        }
        defer { self.waiters = [:] }
        return Array(self.waiters.values)
      }
      if case .success = result { try? FileManager.default.removeItem(at: self.marker) }
      for waiter in waiting {
        switch result {
        case .success: waiter.resume(returning: true)
        case .failure(let error): waiter.resume(throwing: error)
        }
      }
    }
  }

  /// Arms the fence, starts the backup if needed, and waits for it: true once
  /// imports may proceed, false if `timeout` passes first. A failed backup
  /// throws its error, at once while its retry delay lasts.
  func wait(timeout: TimeInterval?, _ backup: @escaping @Sendable () throws -> Void) async throws -> Bool {
    start(backup)
    if isOpen { return true }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
        let finished: Result<Bool, any Error>? = lock.withLock {
          guard running else {
            if backupExists { return .success(true) }
            return .failure(failure ?? CancellationError())
          }
          // Cancelled before this waiter existed: `onCancel` found nothing.
          if Task.isCancelled { return .failure(CancellationError()) }
          waiters[id] = continuation
          return nil
        }
        if let finished { continuation.resume(with: finished); return }
        if let timeout {
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
            self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
          }
        }
      }
    } onCancel: {
      lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
  }
}
