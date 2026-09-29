import Foundation

public enum DatabaseWorkerError: Error, LocalizedError, Equatable, Sendable {
  case atCapacity
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .atCapacity: "The workspace database is busy. Try again when pending work finishes."
    case .timedOut: "The workspace database operation timed out."
    }
  }
}

/// Metadata only: never records SQL, document bodies, or provider payloads.
public struct DatabaseWorkerMetrics: Sendable {
  public var pending = 0
  public var highWaterMark = 0
  public var completed: UInt64 = 0
  public var failed: UInt64 = 0
  public var cancelled: UInt64 = 0
  public var timedOut: UInt64 = 0
  public var rejected: UInt64 = 0
  public var maximumQueueWait: TimeInterval = 0
  public var maximumExecutionTime: TimeInterval = 0
}

/// Cancellation of a queued job is definitive. Once a write starts, it must
/// return its commit/rollback result, even if its caller is subsequently cancelled.
/// Reads may be interrupted; their connections are never shared with another job.
final class DatabaseJobContext: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  let deadline: UInt64

  init(timeout: TimeInterval) {
    deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(timeout, 86_400)) * 1_000_000_000)
  }

  func cancel() { lock.withLock { cancelled = true } }
  func check() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
    if DispatchTime.now().uptimeNanoseconds >= deadline { throw DatabaseWorkerError.timedOut }
  }
}

/// A bounded FIFO drained on a dedicated Dispatch queue, not Swift's cooperative
/// executor. Cancellation removes the pending closure rather than leaving an
/// unbounded series of cancelled Dispatch blocks behind a slow query.
final class DatabaseWorker: @unchecked Sendable {
  private struct Job {
    let id: UUID
    let submitted: UInt64
    let context: DatabaseJobContext
    let run: @Sendable () -> (any Error)?
    let fail: @Sendable (any Error) -> Void
  }
  private let lock = NSLock()
  let queue: DispatchQueue
  private let capacity: Int
  private var jobs: [Job] = []
  private var running: UUID?
  private var scheduled = false
  private var counters = DatabaseWorkerMetrics()
  private var timer: (any DispatchSourceTimer)?

  init(label: String, capacity: Int = 256) {
    precondition(capacity > 0)
    self.capacity = capacity
    queue = DispatchQueue(label: label, qos: .userInitiated)
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.expireQueuedJobs() }
    timer.resume()
    self.timer = timer
  }

  deinit { timer?.cancel() }

  var metrics: DatabaseWorkerMetrics { lock.withLock { counters } }

  func perform<T: Sendable>(timeout: TimeInterval = 30, interruptible: Bool = false,
    _ operation: @escaping @Sendable (DatabaseJobContext) throws -> T
  ) async throws -> T {
    let id = UUID()
    let context = DatabaseJobContext(timeout: timeout)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let job = Job(id: id, submitted: DispatchTime.now().uptimeNanoseconds, context: context,
          run: {
            do {
              try context.check()
              let value = try operation(context)
              if interruptible { try context.check() }
              continuation.resume(returning: value)
              return nil
            } catch { continuation.resume(throwing: error); return error }
          }, fail: { continuation.resume(throwing: $0) })
        enqueue(job)
      }
    } onCancel: {
      context.cancel()
      self.cancel(id)
    }
  }

  private func enqueue(_ job: Job) {
    var failure: (any Error)?
    var start = false
    lock.withLock {
      do { try job.context.check() } catch { failure = error; return }
      guard counters.pending < capacity else {
        counters.rejected += 1
        failure = DatabaseWorkerError.atCapacity
        return
      }
      jobs.append(job)
      counters.pending += 1
      counters.highWaterMark = max(counters.highWaterMark, counters.pending)
      if !scheduled { scheduled = true; start = true }
    }
    if let failure { job.fail(failure) }
    if start { queue.async { self.drain() } }
  }

  private func cancel(_ id: UUID) {
    let removed: Job? = lock.withLock {
      guard let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
      counters.pending -= 1
      counters.cancelled += 1
      return jobs.remove(at: index)
    }
    removed?.fail(CancellationError())
  }

  private func expireQueuedJobs() {
    var expired: [(Job, any Error)] = []
    lock.withLock {
      jobs.removeAll { job in
        do { try job.context.check(); return false }
        catch {
          expired.append((job, error))
          counters.pending -= 1
          if error is CancellationError { counters.cancelled += 1 }
          else { counters.timedOut += 1 }
          return true
        }
      }
    }
    for (job, error) in expired { job.fail(error) }
  }

  private func drain() {
    dispatchPrecondition(condition: .onQueue(queue))
    while true {
      let next: Job? = lock.withLock {
        guard !jobs.isEmpty else { scheduled = false; return nil }
        let job = jobs.removeFirst()
        running = job.id
        counters.maximumQueueWait = max(counters.maximumQueueWait,
          Double(DispatchTime.now().uptimeNanoseconds - job.submitted) / 1_000_000_000)
        return job
      }
      guard let next else { return }
      let began = DispatchTime.now().uptimeNanoseconds
      let failure = next.run()
      lock.withLock {
        if let failure {
          counters.failed += 1
          if failure is CancellationError { counters.cancelled += 1 }
          if (failure as? DatabaseWorkerError) == .timedOut { counters.timedOut += 1 }
        }
        running = nil
        counters.pending -= 1
        counters.completed += 1
        counters.maximumExecutionTime = max(counters.maximumExecutionTime,
          Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000)
      }
    }
  }
}

/// All connections to a workspace in this process share one writer lane. Usage
/// imports therefore cannot race workspace writes on a second SQLite connection.
final class DatabaseWorkers: @unchecked Sendable {
  private final class WeakWorkers {
    weak var value: DatabaseWorkers?
    init(_ value: DatabaseWorkers) { self.value = value }
  }
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [String: WeakWorkers] = [:]
  let writer = DatabaseWorker(label: "wovenmatter.database.writer")
  let readers = (0..<2).map { DatabaseWorker(label: "wovenmatter.database.reader.\($0)", capacity: 128) }

  static func shared(url: URL) -> DatabaseWorkers {
    let key = url.standardizedFileURL.resolvingSymlinksInPath().path
    return registryLock.withLock {
      if let existing = registry[key]?.value { return existing }
      registry = registry.filter { $0.value.value != nil }
      let workers = DatabaseWorkers()
      registry[key] = WeakWorkers(workers)
      return workers
    }
  }
}

/// Connection lifetime, including close, is confined to the assigned worker.
final class DatabaseConnectionBox<Connection: AnyObject>: @unchecked Sendable {
  let worker: DatabaseWorker
  private var connection: Connection?
  private let owner: DatabaseWorkers?
  init(worker: DatabaseWorker, connection: Connection, owner: DatabaseWorkers? = nil) {
    self.owner = owner
    self.worker = worker
    self.connection = connection
  }
  func use<T>(_ body: (Connection) throws -> T) rethrows -> T {
    dispatchPrecondition(condition: .onQueue(worker.queue))
    return try body(connection!)
  }
  deinit {
    // Transfer ownership before scheduling release. Keeping a second reference
    // in this box would let a fast worker drop its reference first, leaving the
    // final close to run on the thread destroying the box.
    let release = ConnectionRelease(connection!)
    connection = nil
    let owner = owner
    worker.queue.async {
      release.close()
      withExtendedLifetime(owner) {}
    }
  }
  private final class ConnectionRelease: @unchecked Sendable {
    private var value: Connection?
    init(_ value: Connection) { self.value = value }
    func close() { value = nil }
  }
}
