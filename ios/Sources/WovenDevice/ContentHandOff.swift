import Foundation
import WovenLibrary
import WovenProtocol

/// What the device made itself (files sent from it, the visual replies of
/// its chats) is in its own content store, and no machine can dial the
/// device to fetch it. So the device hands each server it follows that
/// content once, before the rows that point at it: for each of its own
/// sessions, what the items after the last one handed to that server name.
/// How far each server has been handed is kept in the data folder.
actor ContentHandOff {
  private let library: Library
  private let file: URL
  /// Server → session → the last item handed over.
  private var handed: [String: [String: Int]]

  init(library: Library, file: URL) {
    self.library = library
    self.file = file
    handed = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) } ?? [:]
  }

  func handOver(to client: Client, machineID: String) async throws {
    for session in try await library.sessions(machineID: library.machineID, includeArchived: true) {
      var after = handed[machineID]?[session.id] ?? 0
      while true {
        let items = try await library.items(sessionID: session.id, afterSequence: after)
        guard let last = items.last else { break }
        for item in items {
          for digest in Self.digests(item.content) { try await put(digest, to: client) }
        }
        after = last.sequence
        handed[machineID, default: [:]][session.id] = after
        save()
      }
    }
  }

  /// Forgets a server, once the device no longer follows it.
  func forget(_ machineID: String) {
    guard handed.removeValue(forKey: machineID) != nil else { return }
    save()
  }

  private func put(_ digest: String, to client: Client) async throws {
    if (try? await client.call(FetchContent(digest: digest, length: 0))) != nil { return }
    guard let content = try await library.content(digest) else { return }
    _ = try await client.call(PutContent(data: content.data))
  }

  private static func digests(_ content: ItemContent) -> [String] {
    switch content {
    case .userMessage(_, let attachments): attachments.map(\.digest)
    case .visualReply(let reply): [reply.digest]
    default: []
    }
  }

  private func save() {
    try? JSONEncoder().encode(handed).write(to: file, options: .atomic)
  }
}
