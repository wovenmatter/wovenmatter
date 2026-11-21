import Foundation
import WovenLibrary
import WovenProtocol

/// Databases this machine owns, and the latest copies of the others'.
///
/// The owner's file is `<folder>/<id>.sqlite`. This server is its only
/// writer and carries out its writes one at a time; after each it publishes a
/// copy into the content store and records it on the database's row. A write
/// or delete asked of another machine's database is forwarded to that
/// machine's server. Reads of another machine's database use the latest copy,
/// which is fetched when the library changes, so it is here while the owner
/// is away.
actor Databases {
  /// How long a forwarded change may take to reach this library before the
  /// reply is returned anyway.
  static let syncWait = Duration.seconds(5)

  private let library: Library
  private let peers: PeerSync
  private let folder: URL
  private var lastWrite: Task<Void, Never>?

  init(library: Library, peers: PeerSync, folder: URL) {
    self.library = library
    self.peers = peers
    self.folder = folder
    // Ends when the library closes, which is when the server stops.
    let changes = library.changes()
    Task { [weak self] in
      await self?.fetchMissingCopies()
      for await _ in changes { await self?.fetchMissingCopies() }
    }
  }

  private var thisMachine: String { library.machineID }

  private func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).sqlite") }

  // MARK: Requests

  func list() async throws -> [Database] {
    try await library.databases()
  }

  func create(_ request: CreateDatabase, caller: Caller) async throws -> Database {
    let owner = request.machineID ?? thisMachine
    if owner != thisMachine {
      let database = try await forward(request, to: owner, caller: caller, what: "a database cannot be made there")
      await waitUntil { try await $0.database(database.id) != nil }
      return database
    }
    let name = try Library.databaseName(request.name)
    let source: URL? = if let sourceID = request.copyOf {
      try await copyFile(of: try await existing(sourceID))
    } else {
      nil
    }
    return try await serially { [library, folder] in
      let id = UUID().uuidString.lowercased()
      let url = folder.appendingPathComponent("\(id).sqlite")
      do {
        if let source {
          try await offThread { try DatabaseFile.adopt(copy: source, at: url) }
        } else {
          try await offThread { try DatabaseFile.create(at: url) }
        }
        let copy = try await Self.publish(url, library: library)
        return try await library.createDatabase(id: id, name: name, description: request.description, copy: copy)
      } catch {
        DatabaseFile.remove(at: url)
        throw error
      }
    }
  }

  func execute(_ request: ExecuteDatabase, caller: Caller) async throws -> DatabaseWritten {
    let database = try await existing(request.databaseID)
    if database.machineID != thisMachine {
      let written = try await forward(request, to: database.machineID, caller: caller,
                                      what: "\(database.name) cannot be changed until it is back")
      let digest = written.database.copyDigest
      await waitUntil { try await $0.database(database.id)?.copyDigest == digest }
      return written
    }
    let url = file(database.id)
    return try await serially { [library] in
      let changes = try await offThread { try DatabaseFile(url: url, isCopy: false).execute(request.sql) }
      let copy = try await Self.publish(url, library: library)
      return DatabaseWritten(database: try await library.recordDatabaseCopy(database.id, copy), changes: changes)
    }
  }

  func query(_ request: QueryDatabase) async throws -> DatabaseRows {
    let (_, file) = try await readable(request.databaseID)
    let result = try await offThread { try file.query(request.sql) }
    return DatabaseRows(columns: result.columns, rows: result.rows, json: result.json, fromCopy: file.isCopy)
  }

  func describe(_ request: DescribeDatabase) async throws -> DatabaseDescription {
    let (database, file) = try await readable(request.databaseID)
    let tables = try await offThread { try file.describe() }
    return DatabaseDescription(database: database, tables: tables, fromCopy: file.isCopy)
  }

  func delete(_ request: DeleteDatabase, caller: Caller) async throws -> Done {
    let database = try await existing(request.databaseID)
    if database.machineID != thisMachine {
      let done = try await forward(request, to: database.machineID, caller: caller,
                                   what: "\(database.name) cannot be deleted until it is back")
      await waitUntil { try await $0.database(database.id) == nil }
      return done
    }
    let url = file(database.id)
    return try await serially { [library] in
      try await library.deleteDatabase(database.id)
      DatabaseFile.remove(at: url)
      return Done()
    }
  }

  // MARK: Helpers

  private func existing(_ id: String) async throws -> Database {
    guard let database = try await library.database(id) else { throw ProtocolError(.notFound, "No database \(id).") }
    return database
  }

  /// The owner's file here, or elsewhere the latest copy.
  private func readable(_ id: String) async throws -> (Database, DatabaseFile) {
    let database = try await existing(id)
    if database.machineID == thisMachine { return (database, DatabaseFile(url: file(id), isCopy: false)) }
    return (database, DatabaseFile(url: try await copyFile(of: database), isCopy: true))
  }

  /// The latest published copy of a database, fetched from a linked machine
  /// when this one does not hold it.
  private func copyFile(of database: Database) async throws -> URL {
    guard let digest = database.copyDigest else {
      throw ProtocolError(.notFound, "\(database.name) has no published copy yet.")
    }
    if let url = try await library.contentFile(digest) { return url }
    if await peers.fetchContent(digest), let url = try await library.contentFile(digest) { return url }
    throw ProtocolError(.ownerUnreachable,
                        "The latest copy of \(database.name) is not on this machine and no linked machine could send it.")
  }

  /// Fetches the latest copy of every other machine's database that this
  /// machine does not hold yet.
  private func fetchMissingCopies() async {
    guard let databases = try? await library.databases() else { return }
    for database in databases where database.machineID != thisMachine {
      guard let digest = database.copyDigest, (try? await library.hasContent(digest)) == false else { continue }
      _ = await peers.fetchContent(digest)
    }
  }

  /// Sends a request to the owning machine's server and returns its reply. A
  /// request that came from another server is never sent on again.
  private func forward<R: Request>(_ request: R, to owner: String, caller: Caller, what: String) async throws -> R.Reply {
    guard caller.hello.role != .server else {
      throw ProtocolError(.notOwner, "This machine does not own that database.", machineID: owner)
    }
    let name = (try? await library.machine(owner))?.name ?? owner
    let unreachable = ProtocolError(.ownerUnreachable, "\(name) is not reachable, so \(what).", machineID: owner)
    guard let client = await peers.client(for: owner) else { throw unreachable }
    do {
      return try await client.call(request)
    } catch let error as ProtocolError {
      throw error
    } catch {
      throw unreachable
    }
  }

  /// Waits, for a few seconds at most, until `condition` holds in this
  /// library, so a read right after a forwarded change sees it.
  private func waitUntil(_ condition: @escaping @Sendable (Library) async throws -> Bool) async {
    let changes = library.changes()
    let library = library
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        if (try? await condition(library)) == true { return }
        for await _ in changes {
          if (try? await condition(library)) == true { return }
        }
      }
      group.addTask { try? await Task.sleep(for: Self.syncWait) }
      await group.next()
      group.cancelAll()
    }
  }

  /// Runs owner-side changes one at a time, in the order they arrive.
  private func serially<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let previous = lastWrite
    let task = Task {
      await previous?.value
      return try await body()
    }
    lastWrite = Task { _ = await task.result }
    return try await task.value
  }

  /// Makes a copy of the owner's file and moves it into the content store.
  private static func publish(_ url: URL, library: Library) async throws -> ContentRef {
    let target = try library.incomingFile()
    do {
      try await offThread { try DatabaseFile(url: url, isCopy: false).copy(to: target) }
      let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
      return ContentRef(digest: try await library.storeContent(movingFile: target), size: size)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw error
    }
  }
}

/// Runs blocking SQLite work on a thread of its own rather than the shared pool.
private func offThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
  }
}

func registerDatabases(_ router: inout Router, databases: Databases) {
  router.on(ListDatabases.self) { _, _ in
    try await databases.list()
  }
  router.on(CreateDatabase.self) { request, caller in
    try await databases.create(request, caller: caller)
  }
  router.on(DescribeDatabase.self) { request, _ in
    try await databases.describe(request)
  }
  router.on(ExecuteDatabase.self) { request, caller in
    try await databases.execute(request, caller: caller)
  }
  router.on(QueryDatabase.self) { request, _ in
    try await databases.query(request)
  }
  router.on(DeleteDatabase.self) { request, caller in
    try await databases.delete(request, caller: caller)
  }
}
