import Foundation
import WovenMatterCore

/// A row of the library this build could not read.
///
/// Every device runs the same build and every row was written by it, so a
/// row that does not decode is damaged. A list is not lost to one such row:
/// it shows every row it can read, leaves the damaged one out and records it
/// here, and Settings says which records are affected. Reading or writing
/// that one row by its ID fails with the decoding error.
public struct UnreadableRecord: Codable, Hashable, Sendable {
  /// What the row is, in words a person reads: `workspace`, `note`.
  public let kind: String
  public let id: String
  public init(kind: String, id: String) { self.kind = kind; self.id = id }
}

/// The unreadable rows found in each open library, by its support directory.
enum UnreadableRecords {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var found: [String: [String: Set<String>]] = [:]

  /// The rows of `kind` a whole read of them just found unreadable: the
  /// ones found before are replaced, so a repaired row is no longer reported.
  static func replace(_ kind: String, ids: [String], in library: URL) {
    let appeared = lock.withLock { () -> Set<String> in
      let before = found[key(library)]?[kind] ?? []
      found[key(library), default: [:]][kind] = ids.isEmpty ? nil : Set(ids)
      return Set(ids).subtracting(before)
    }
    report(kind, appeared)
  }

  /// A row of `kind` found unreadable by a read of some of them.
  static func add(_ kind: String, id: String, in library: URL) {
    let appeared = lock.withLock { found[key(library), default: [:]][kind, default: []].insert(id).inserted }
    if appeared { report(kind, [id]) }
  }

  static func all(in library: URL) -> [UnreadableRecord] {
    lock.withLock { found[key(library)] ?? [:] }
      .flatMap { kind, ids in ids.map { UnreadableRecord(kind: kind, id: $0) } }
      .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
  }

  private static func key(_ library: URL) -> String { library.standardizedFileURL.resolvingSymlinksInPath().path }
  private static func report(_ kind: String, _ ids: Set<String>) {
    for id in ids.sorted() { NSLog("The library holds a %@ that cannot be read and is left out of lists: %@", kind, id) }
  }
}

extension WorkspaceDatabaseConnection {
  /// The library's rows that could not be read since it was opened.
  public func unreadableRecords() -> [UnreadableRecord] { UnreadableRecords.all(in: libraryFiles.supportDirectory) }

  func replaceUnreadable(_ kind: String, ids: [String]) { UnreadableRecords.replace(kind, ids: ids, in: libraryFiles.supportDirectory) }
  func addUnreadable(_ kind: String, id: String) { UnreadableRecords.add(kind, id: id, in: libraryFiles.supportDirectory) }
}

extension WorkspaceDatabase {
  public func unreadableRecords() async throws -> [UnreadableRecord] { try await read { $0.unreadableRecords() } }
}
