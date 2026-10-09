import Foundation

/// Decoded Program Status Protocol (OSC 7501) records. This is a structured
/// projection, not a replacement for native transport or durable run outcomes.
public struct ProgramStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case idle, working, blocked, done, error
    /// A record removal instruction, never a displayed state.
    case clear
  }
  public enum Kind: String, Codable, Sendable {
    case permission, question, auth
  }

  public let state: State
  public let id: String?
  public let app: String?
  public let kind: Kind?
  public let progress: Int?
  public let title: String?
  public let message: String?

  enum CodingKeys: String, CodingKey {
    case state, id, app, kind, progress, title
    case message = "msg"
  }

  public init(state: State, id: String? = nil, app: String? = nil, kind: Kind? = nil,
              progress: Int? = nil, title: String? = nil, message: String? = nil) {
    self.state = state
    self.id = id
    self.app = app
    self.kind = state == .blocked ? kind : nil
    self.progress = [.working, .blocked].contains(state) ? progress.flatMap { (0...100).contains($0) ? $0 : nil } : nil
    self.title = title
    self.message = message
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(state: try values.decode(State.self, forKey: .state),
      id: try values.decodeIfPresent(String.self, forKey: .id),
      app: try? values.decode(String.self, forKey: .app),
      kind: try? values.decode(Kind.self, forKey: .kind),
      progress: try? values.decode(Int.self, forKey: .progress),
      title: try values.decodeIfPresent(String.self, forKey: .title),
      message: try values.decodeIfPresent(String.self, forKey: .message))
  }

  public var isActive: Bool { state == .working || state == .blocked }
  public var label: String { state.rawValue.capitalized }

  /// Validate before applying any part of a report. Text is already decoded
  /// UTF-8; terminal control characters must never reach other app surfaces.
  public var validated: Self? {
    if let id {
      let segments = id.split(separator: "/", omittingEmptySubsequences: false)
      guard id.utf8.count <= 128, segments.count <= 8,
            segments.allSatisfy({ Self.validName(String($0)) }) else { return nil }
    }
    for (text, limit) in [(message, 2048), (title, 192)] {
      if let text {
        guard text.utf8.count <= limit, !text.unicodeScalars.contains(where: Self.isControl) else { return nil }
      }
    }
    return Self(state: state, id: id, app: app.flatMap { Self.validName($0) ? $0 : nil },
                kind: kind, progress: progress, title: title, message: message)
  }

  public static func message(_ text: String?) -> String? {
    guard let text else { return nil }
    let safe = WorkspaceHistoryPrivacy.redactingToolEndpoints(text)
    let clean = String(String.UnicodeScalarView(safe.unicodeScalars.map { isControl($0) ? " " : $0 }))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var result = "", bytes = 0
    for scalar in clean.unicodeScalars {
      let count = scalar.utf8.count
      if bytes + count > 2048 { break }
      result.unicodeScalars.append(scalar); bytes += count
    }
    return result.isEmpty ? nil : result
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
  }
  private static func validName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || [95, 46, 43, 45].contains($0)
    }
  }

  /// Legacy database/native values stay at their compatibility boundaries.
  /// Queued, cancelled and uncertain are workflow facts, not new OSC states.
  public static func run(_ value: String?, error: String? = nil, app: String? = nil) -> Self? {
    switch value {
    case "running", "streaming", "in_progress", "working": Self(state: .working, app: app)
    case "blocked": Self(state: .blocked, app: app)
    case "completed", "succeeded", "done": Self(state: .done, app: app)
    case "failed", "error": Self(state: .error, app: app, message: message(error))
    case "cancelled", "canceled", "aborted", "stopped", "idle": Self(state: .idle, app: app)
    default: nil
    }
  }
}

/// One reporter's records, ordered by last update. Updates replace whole records;
/// clearing a parent also clears its descendants. No heartbeat is required.
public struct ProgramStatusRecords: Codable, Equatable, Sendable {
  public private(set) var records: [ProgramStatus] = []
  public init() {}

  /// App identity is inherited at projection time, without changing the
  /// replacement record. Clearing an ancestor therefore also clears inheritance.
  public var resolvedRecords: [ProgramStatus] {
    records.map { report in
      var app = report.app
      var segments = report.id?.split(separator: "/").map(String.init) ?? []
      while app == nil, !segments.isEmpty {
        segments.removeLast()
        let parent = segments.isEmpty ? nil : segments.joined(separator: "/")
        app = records.first { $0.id == parent }?.app
      }
      return ProgramStatus(state: report.state, id: report.id, app: app, kind: report.kind,
        progress: report.progress, title: report.title, message: report.message)
    }
  }

  @discardableResult public mutating func apply(_ report: ProgramStatus) -> Bool {
    guard let report = report.validated else { return false }
    let previous = records
    if report.state == .clear {
      if let id = report.id { records.removeAll { $0.id == id || $0.id?.hasPrefix(id + "/") == true } }
      else { records.removeAll() }
    } else {
      records.removeAll { $0.id == report.id }
      records.append(report)
      if records.count > 256 { records.removeFirst(records.count - 256) }
    }
    return previous != records
  }
}

public struct ProgramStatusSnapshot: Codable, Equatable, Sendable {
  public let runID: String?
  /// Delivery, cancellation and recovery remain separate workflow facts.
  public let executionStatus: String?
  public let status: ProgramStatus?
  public let records: [ProgramStatus]

  public init(runID: String? = nil, executionStatus: String? = nil,
              status: ProgramStatus? = nil, records: [ProgramStatus] = []) {
    self.runID = runID; self.executionStatus = executionStatus
    self.status = status; self.records = records
  }

  public static func run(id: String, executionStatus: String, error: String?, app: String?,
                         reports: [ProgramStatus]) -> Self {
    // Independent decision reporters can address the same root. Project one
    // record per ID, keeping a live block until its owning source clears it.
    var records: [ProgramStatus] = []
    for report in reports {
      if let index = records.firstIndex(where: { $0.id == report.id }) {
        if records[index].state == .blocked && report.state != .blocked { continue }
        records.remove(at: index)
      }
      records.append(report)
    }
    let outcome = ProgramStatus.run(executionStatus, error: error, app: app)
    guard executionStatus == "running" else {
      // A lost connection cannot prove idle or completion. Terminal native
      // outcomes expire active records, including unresolved decision overlays.
      return Self(runID: id, executionStatus: executionStatus, status: outcome,
                  records: records.filter { !$0.isActive })
    }
    let blocked = records.last { $0.state == .blocked }
    let root = records.last { $0.id == nil && $0.state == .working }
    return Self(runID: id, executionStatus: executionStatus,
                status: blocked.map { ProgramStatus(state: .blocked, app: $0.app ?? app,
                  kind: $0.kind, progress: $0.progress, title: $0.title, message: $0.message) }
                  ?? root ?? outcome, records: records)
  }
}
