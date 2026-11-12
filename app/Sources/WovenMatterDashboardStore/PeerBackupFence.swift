import Foundation
import WovenMatterCore

/// The one-time recovery backup that precedes a library's first peer import
/// (`Paired Mac Backups/before-peer-sync.sqlite`), shared by every handle on
/// one database file.
///
/// The copy reads its own connection on its own queue, never a worker lane:
/// a multi-gigabyte library takes minutes to copy and verify, and every other
/// database job keeps its normal 30-second bound meanwhile. Nothing in pairing
/// waits for it. Only peer imports do: once armed, the library accepts no
/// peer page until the backup exists, which keeps the backup a copy of the
/// library from before pairing.
final class PeerBackupFence: @unchecked Sendable {
  private let lock = NSLock()
  /// The first synchronization waits for this copy, so it runs at the database
  /// lanes' QoS: a utility queue has its disk reads throttled under load.
  private let queue = DispatchQueue(label: "wovenmatter.database.peer-backup", qos: DispatchQoS(qosClass: PortablePOSIX.waitedOnQoS, relativePriority: 0))
  private var armed = false
  private var running = false
  private var failure: (any Error)?
  private var waiters: [UUID: CheckedContinuation<Bool, any Error>] = [:]

  /// Imports may proceed: the fence was never armed, or the backup exists.
  func isOpen(_ file: URL) -> Bool {
    lock.withLock { !armed } || FileManager.default.fileExists(atPath: file.path)
  }

  /// Arms the fence and starts `backup` unless it is running or done. A
  /// failed attempt is retried by the next call.
  func start(_ file: URL, _ backup: @escaping @Sendable () throws -> Void) {
    let begin: Bool = lock.withLock {
      armed = true
      guard !running, !FileManager.default.fileExists(atPath: file.path) else { return false }
      running = true; failure = nil
      return true
    }
    guard begin else { return }
    queue.async {
      let result = Result { try backup() }
      let waiting: [CheckedContinuation<Bool, any Error>] = self.lock.withLock {
        self.running = false
        if case .failure(let error) = result { self.failure = error }
        defer { self.waiters = [:] }
        return Array(self.waiters.values)
      }
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
  /// throws its error.
  func wait(_ file: URL, timeout: TimeInterval?, _ backup: @escaping @Sendable () throws -> Void) async throws -> Bool {
    start(file, backup)
    if isOpen(file) { return true }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
        let finished: Result<Bool, any Error>? = lock.withLock {
          guard running else {
            if FileManager.default.fileExists(atPath: file.path) { return .success(true) }
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
