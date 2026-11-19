import Foundation
import Synchronization
import WovenProtocol

/// Something the library refused to do.
public struct LibraryError: Error, CustomStringConvertible, Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case notFound
    case notOwner(machineID: String)
    case invalid
    case closed
  }

  public let kind: Kind
  public let description: String

  init(_ kind: Kind, _ description: String) {
    self.kind = kind
    self.description = description
  }
}

/// This machine's library: one SQLite file with one writer on one serial
/// lane, and reads on their own connections that never wait for it.
public final class Library: Sendable {
  public let machineID: String
  public let folder: URL
  private let lane: WriteLane
  private let readers: ReaderPool
  private let watchers = Mutex<[UUID: AsyncStream<Int64>.Continuation]>([:])
  private let latest: Mutex<Int64>

  public var fileURL: URL { folder.appendingPathComponent("library.sqlite") }

  /// Opens (or creates) `library.sqlite` in `folder`. `machineName` names this
  /// machine the first time only.
  public static func open(folder: URL, machineName: String) async throws -> Library {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("library.sqlite").path
    let lane = WriteLane()
    let (machineID, changed) = try await lane.open(path: path, machineName: machineName)
    return Library(machineID: machineID, folder: folder, lane: lane, changed: changed)
  }

  private init(machineID: String, folder: URL, lane: WriteLane, changed: Int64) {
    self.machineID = machineID
    self.folder = folder
    self.lane = lane
    self.readers = ReaderPool(path: folder.appendingPathComponent("library.sqlite").path)
    self.latest = Mutex(changed)
  }

  /// The library's `changed` counter after the last commit.
  public var changed: Int64 { latest.withLock { $0 } }

  /// The counter after every later commit that changed synced rows. Values
  /// a slow reader has not taken yet are folded into the newest.
  public func changes() -> AsyncStream<Int64> {
    let (stream, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    watchers.withLock { $0[id] = continuation }
    continuation.onTermination = { [weak self] _ in _ = self?.watchers.withLock { $0.removeValue(forKey: id) } }
    return stream
  }

  /// Closes both connections. Later calls fail with `closed`.
  public func close() async {
    await lane.close()
    readers.close()
    watchers.withLock { watchers in
      for continuation in watchers.values { continuation.finish() }
      watchers.removeAll()
    }
  }

  /// Runs `body` as one transaction on the write lane.
  func write<T: Sendable>(_ body: @escaping @Sendable (Writer) throws -> T) async throws -> T {
    let (result, counter, moved) = try await lane.run(body)
    if moved {
      latest.withLock { $0 = counter }
      for continuation in watchers.withLock({ Array($0.values) }) { continuation.yield(counter) }
    }
    return result
  }

  /// Runs `body` on a read connection inside one read transaction.
  func read<T: Sendable>(_ body: @escaping @Sendable (Connection) throws -> T) async throws -> T {
    try await readers.read(body)
  }
}

/// The one writer. Its connection, clock and counter are only touched on its
/// queue.
private final class WriteLane: @unchecked Sendable {
  private let queue = DispatchQueue(label: "woven.library.writer")
  private var writer: Writer?

  func open(path: String, machineName: String) async throws -> (String, Int64) {
    try await onQueue {
      let connection = try Connection(path: path, readOnly: false)
      try connection.execute("PRAGMA journal_mode = WAL")
      try connection.execute("PRAGMA synchronous = NORMAL")
      try Schema.apply(to: connection)
      let writer = try Writer.open(connection, machineName: machineName)
      self.writer = writer
      return (writer.machineID, writer.counter)
    }
  }

  func close() async {
    _ = try? await onQueue { self.writer = nil }
  }

  func run<T: Sendable>(_ body: @escaping @Sendable (Writer) throws -> T) async throws -> (T, Int64, Bool) {
    try await onQueue {
      guard let writer = self.writer else { throw LibraryError(.closed, "The library is closed.") }
      return try writer.transaction(body)
    }
  }

  private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try body() }) }
    }
  }
}

/// Read connections, opened as needed and reused. WAL lets them read while
/// the writer writes.
private final class ReaderPool: Sendable {
  private let path: String
  private let idle = Mutex<(open: Bool, connections: [Connection])>((true, []))

  init(path: String) {
    self.path = path
  }

  func read<T: Sendable>(_ body: @escaping @Sendable (Connection) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result {
          guard let connection = try self.take() else { throw LibraryError(.closed, "The library is closed.") }
          defer { self.give(connection) }
          return try connection.snapshot { try body(connection) }
        })
      }
    }
  }

  func close() {
    idle.withLock { $0 = (false, []) }
  }

  private func take() throws -> Connection? {
    let state = idle.withLock { state -> (Bool, Connection?) in
      (state.open, state.connections.popLast())
    }
    guard state.0 else { return nil }
    return try state.1 ?? Connection(path: path, readOnly: true)
  }

  private func give(_ connection: Connection) {
    idle.withLock { state in
      if state.open && state.connections.count < 8 { state.connections.append(connection) }
    }
  }
}
