import Foundation
import WovenLibrary
import WovenProtocol

/// What the device made itself (files sent from it, the visual replies of
/// its chats) is in its own content store, and no machine can dial the
/// device to fetch it. So the device hands each server it follows that
/// content once, before the rows that point at it: for each of its own
/// sessions, what the items after the last one handed to that server name.
/// A file the server does not take waits for the next connection to that
/// server and never holds up the rows. How far each server has been handed,
/// and what waits, is kept in the data folder.
actor ContentHandOff {
  /// The largest file one `content.put` carries: a message is at most 64 MiB
  /// on either side of a connection, and the file travels in it as base64.
  /// A larger one is not sent.
  static let largestFile: Int64 = (64 << 20) / 4 * 3 - (64 << 10)

  private struct Record: Codable {
    /// Server → session → the last item handed over.
    var handed: [String: [String: Int]] = [:]
    /// Server → files it did not take, tried again on the next connection.
    var waiting: [String: Set<String>] = [:]
  }

  private let library: Library
  private let file: URL
  private var record: Record

  init(library: Library, file: URL) {
    self.library = library
    self.file = file
    record = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
  }

  /// Hands the server what it lacks. `fresh` on a new connection, when the
  /// files that waited are tried again. Only reading the library can fail.
  func handOver(to client: Client, machineID: String, fresh: Bool = false) async throws {
    if fresh {
      for digest in record.waiting[machineID] ?? [] {
        if await put(digest, to: client) { record.waiting[machineID]?.remove(digest) }
      }
      save()
    }
    for session in try await library.sessions(machineID: library.machineID, includeArchived: true) {
      var after = record.handed[machineID]?[session.id] ?? 0
      while true {
        let items = try await library.items(sessionID: session.id, afterSequence: after)
        guard let last = items.last else { break }
        for item in items {
          for digest in Self.digests(item.content) {
            if await !put(digest, to: client) { record.waiting[machineID, default: []].insert(digest) }
          }
        }
        after = last.sequence
        record.handed[machineID, default: [:]][session.id] = after
        save()
      }
    }
  }

  /// Forgets a server, once the device no longer follows it.
  func forget(_ machineID: String) {
    let handed = record.handed.removeValue(forKey: machineID)
    let waiting = record.waiting.removeValue(forKey: machineID)
    if handed != nil || waiting != nil { save() }
  }

  /// True when the server holds the file now, or never will (it is too large
  /// to send, or this device no longer holds it).
  private func put(_ digest: String, to client: Client) async -> Bool {
    if (try? await client.call(FetchContent(digest: digest, length: 0))) != nil { return true }
    let stored: ContentChunk?
    do { stored = try await library.content(digest, length: 0) } catch { return false }
    guard let stored, stored.size <= Self.largestFile else { return true }
    guard let content = try? await library.content(digest) else { return false }
    return (try? await client.call(PutContent(data: content.data))) != nil
  }

  private static func digests(_ content: ItemContent) -> [String] {
    switch content {
    case .userMessage(_, let attachments): attachments.map(\.digest)
    case .visualReply(let reply): [reply.digest]
    default: []
    }
  }

  private func save() {
    try? JSONEncoder().encode(record).write(to: file, options: .atomic)
  }
}
