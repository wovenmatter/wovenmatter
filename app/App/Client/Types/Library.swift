import CryptoKit
import Foundation
import WovenProtocol

extension LibraryItemKind {
  var title: String {
    switch self {
    case .file: "Files"
    case .link: "Links"
    case .photo: "Photos"
    }
  }
}

enum LibrarySender: String, Codable, CaseIterable, Sendable {
  case me, agent
  var title: String { self == .me ? "Sent by me" : "Sent by agents" }
}

enum LibraryDateRange: String, CaseIterable, Identifiable, Sendable {
  case today, week, month, quarter, all
  var id: String { rawValue }
  var title: String {
    switch self {
    case .today: "Today"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    case .quarter: "Last 90 days"
    case .all: "All time"
    }
  }
  func start(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
    let days: Int
    switch self {
    case .today: days = 0
    case .week: days = 6
    case .month: days = 29
    case .quarter: days = 89
    case .all: return nil
    }
    return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
  }
}

/// A Library filter and search. `nil` means all; an empty set matches nothing.
struct LibraryQuery: Equatable, Sendable {
  var machines: Set<String>?
  var harnesses: Set<String>?
  var agents: Set<String>?
  var sender: LibrarySender?
  var kind: LibraryItemKind?
  var since: Date?
  var until: Date?
  var search = ""
  var oldestFirst = false
  init() {}
}

/// Where a Library item's content is.
enum LibraryStorage: String, Codable, Sendable {
  case link, pending, attachment, retained, unavailable, unsupported
}

/// A file, link or photo exchanged in a chat, as the Library lists it.
struct WorkspaceLibraryItem: Equatable, Identifiable, Sendable {
  /// The same item, from the message it was sent in and its source, on every machine.
  static func identifier(messageID: String, source: String) -> String {
    SHA256.hash(data: Data((messageID + "\u{0}" + source).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  let id: String
  let conversationID: String
  let messageID: String
  let conversationTitle: String
  /// The machine whose session sent or received it.
  let machineID: String
  let machineName: String
  let harness: String
  let agentID: String
  let agentName: String
  let sender: LibrarySender
  let kind: LibraryItemKind
  let title: String
  let source: String
  let sentAt: Date
  let hasContent: Bool
  let storage: LibraryStorage
  let error: String?
  var canOpen: Bool { (storage == .link && isWebLink) || hasContent }
  var isWebLink: Bool { ["http", "https"].contains(URL(string: source)?.scheme?.lowercased() ?? "") }
}

/// One agent on one machine that has Library items, for the filters.
struct LibraryFacet: Equatable, Identifiable, Sendable {
  let machineID: String
  let machineName: String
  let harness: String
  let agentID: String
  let agentName: String
  var id: String { machineID + ":" + agentID }
}

/// A file an agent saved from a machine, as Saved Artifacts lists it.
struct SavedArtifactLibraryItem: Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let mediaType: String
  let byteCount: Int64
  let machineID: String
  let machineName: String
}

/// A Library request that failed, with a message for the person.
struct LibraryFailure: LocalizedError, Equatable, Sendable {
  let message: String
  var errorDescription: String? { message }
}
