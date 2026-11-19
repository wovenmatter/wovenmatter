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
  private let removedState = Mutex(false)

  public var fileURL: URL { folder.appendingPathComponent("library.sqlite") }

  /// Opens (or creates) `library.sqlite` in `folder`. `machineName` names this
  /// machine the first time only. A library whose machine was removed is
  /// erased here, with its content store, and begins again empty under a new
  /// identifier.
  public static func open(folder: URL, machineName: String) async throws -> Library {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("library.sqlite").path
    let lane = WriteLane()
    let (machineID, changed) = try await lane.open(path: path, machineName: machineName, erase: {
      for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm", "files"] {
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      }
    })
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

  /// Another machine removed this one, and this library has received that.
  /// From then on it refuses every write (they fail with `closed`), and its
  /// `changes()` streams end. The server should stop; at the next `open`
  /// the library is erased and begins again as a new machine.
  public var isRemoved: Bool { removedState.withLock { $0 } }

  /// The counter after every later commit that changed synced rows. Values
  /// a slow reader has not taken yet are folded into the newest. The stream
  /// ends when the library closes or this machine is removed.
  public func changes() -> AsyncStream<Int64> {
    let (stream, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    if isRemoved {
      continuation.finish()
      return stream
    }
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
    let (result, counter, moved, removed) = try await lane.run(body)
    if moved {
      latest.withLock { $0 = counter }
      for continuation in watchers.withLock({ Array($0.values) }) { continuation.yield(counter) }
    }
    if removed, removedState.withLock({ was in defer { was = true }; return !was }) {
      let ending = watchers.withLock { watchers in
        defer { watchers.removeAll() }
        return Array(watchers.values)
      }
      for continuation in ending { continuation.finish() }
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

  func open(path: String, machineName: String, erase: @escaping @Sendable () throws -> Void) async throws -> (String, Int64) {
    try await onQueue {
      func connect() throws -> Connection {
        let connection = try Connection(path: path, readOnly: false)
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = NORMAL")
        try Schema.apply(to: connection)
        return connection
      }
      var connection: Connection? = try connect()
      if try Writer.wasRemoved(connection!) {
        connection = nil  // The only handle on the file closes before the file goes.
        try erase()
        connection = try connect()
      }
      let writer = try Writer.open(connection!, machineName: machineName)
      self.writer = writer
      return (writer.machineID, writer.counter)
    }
  }

  func close() async {
    _ = try? await onQueue { self.writer = nil }
  }

  /// Runs `body` as one transaction. Returns its result, the counter after,
  /// whether the counter moved, and whether this machine is now removed.
  func run<T: Sendable>(_ body: @escaping @Sendable (Writer) throws -> T) async throws -> (T, Int64, Bool, Bool) {
    try await onQueue {
      guard let writer = self.writer else { throw LibraryError(.closed, "The library is closed.") }
      let (result, counter, moved) = try writer.transaction(body)
      return (result, counter, moved, writer.removed)
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
