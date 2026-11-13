import Foundation
import WovenMatterShared

/// A session another machine runs, read from its `LibraryTranscript` into the
/// same records the conversation view renders for a session this Mac runs,
/// and the reverse for the transcript this Mac serves for its own sessions.
/// Activities keep their canonical `AgentRunActivity` projections; whatever a
/// compact projection leaves out is read when its disclosure opens.
public struct RemoteConversationRecords: Equatable, Sendable {
  public let messages: [WorkspaceMessageRecord]
  public let runs: [WorkspaceRunRecord]
  public let activities: [WorkspaceRunActivityRecord]
  public let attachments: [WorkspaceMessageAttachmentRecord]

  private static let settled: Set<String> = ["completed", "failed", "cancelled", "interrupted"]

  public init(_ transcript: LibraryTranscript) {
    let conversationID = transcript.conversationID
    let messages = Self.joiningParts(transcript.messages)
    let infos = Dictionary((transcript.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var runIDs: [String] = []
    var seen: Set<String> = []
    func note(_ id: String?) { if let id, !id.isEmpty, seen.insert(id).inserted { runIDs.append(id) } }
    for run in transcript.runs ?? [] { note(run.id) }
    for message in messages { note(message.runID) }
    for activity in transcript.activities { note(activity.runID) }
    note(transcript.activeRunID)
    let messageIDs = Set(messages.map(\.id))

    var runs: [WorkspaceRunRecord] = []
    for id in runIDs {
      let info = infos[id]
      let own = messages.filter { $0.runID == id }
      let user = info?.userMessageID.flatMap { messageIDs.contains($0) ? $0 : nil }
        ?? own.first { $0.role == "user" }?.id
      let assistant = info?.assistantMessageID.flatMap { messageIDs.contains($0) ? $0 : nil }
        ?? own.first { $0.role == "assistant" && $0.id == id }?.id
        ?? own.last { $0.role == "assistant" }?.id
      let reply = own.first { $0.id == assistant }
      // A terminal run snapshot wins over a stale active-run or message flag.
      let status: String
      if let value = info?.status { status = value }
      else if transcript.activeRunID == id { status = "running" }
      else if let value = reply?.status, Self.settled.contains(value) { status = value }
      else { status = "completed" }
      let startedAt = info?.startedAt ?? own.first?.createdAt
      runs.append(WorkspaceRunRecord(id: id, conversationID: conversationID, agentID: nil,
        userMessageID: user, assistantMessageID: assistant, status: status, error: nil,
        startedAt: startedAt, completedAt: info?.completedAt, createdAt: startedAt, updatedAt: info?.completedAt ?? startedAt))
    }
    let runStatus = Dictionary(runs.map { ($0.id, $0.status) }, uniquingKeysWith: { _, latest in latest })

    self.messages = messages.map { message in
      var status = message.status
      // Execution owners mark a reply in progress as running; the view calls it streaming.
      if message.role == "assistant", status == "running" || status == "streaming" {
        status = message.runID.flatMap { runStatus[$0] }.map { $0 == "running" ? "streaming" : $0 } ?? "streaming"
      }
      return WorkspaceMessageRecord(senderKind: message.senderKind.flatMap(WorkspaceSessionDeliveryKind.init(rawValue:)),
        senderSessionID: message.agentSourceID, senderAgent: message.senderHarness, senderSessionTitle: message.senderSessionTitle,
        id: message.id, conversationID: conversationID, clientMessageID: nil, runID: message.runID,
        role: message.role, content: message.content, status: status, createdAt: message.createdAt,
        updatedAt: nil)
    }
    self.runs = runs
    activities = transcript.activities.enumerated().map { offset, activity in
      let decoded = activity.projectionJSON.flatMap { try? JSONDecoder().decode(AgentRunActivity.self, from: Data($0.utf8)) }
      var projected = decoded ?? AgentRunActivity(id: activity.id, kind: .tool, title: activity.title,
        status: activity.status, content: activity.detail)
      // The row's status is the owner's; a projection may predate its settling.
      let rowSettled = Self.settled.contains(activity.status)
      let needsStatus = !activity.status.isEmpty && (projected.status == nil || (rowSettled && !Self.settled.contains(projected.status ?? "")))
      let needsPosition = projected.position == nil && activity.sequence != nil
      let needsDetails = activity.detailsRecordID != nil && projected.detailsAvailable != true
      if needsStatus || needsPosition || needsDetails {
        projected = projected.merging(AgentRunActivity(id: projected.id, kind: projected.kind,
          status: needsStatus ? activity.status : nil, position: needsPosition ? activity.sequence.map(Int.init) : nil,
          detailsAvailable: needsDetails ? true : nil))
      }
      return WorkspaceRunActivityRecord(id: activity.id, runID: activity.runID, conversationID: conversationID,
        activity: projected, createdAt: activity.createdAt ?? "", sequence: activity.sequence ?? (activity.createdAt == nil ? Int64(offset) : nil))
    }
    attachments = messages.flatMap { message in
      (message.attachments ?? []).map { file in
        WorkspaceMessageAttachmentRecord(id: message.id + ":" + file.id, conversationID: conversationID, messageID: message.id,
          kind: file.mimeType.hasPrefix("image/") ? .image : .file, fileName: file.name, mimeType: file.mimeType,
          sizeBytes: file.byteCount ?? 0, contentHash: Self.isDigest(file.id) ? file.id : nil,
          createdAt: message.createdAt)
      }
    }
  }

  /// The transcript this Mac serves for a session it runs: each activity's
  /// compact projection, and each run's timing and messages.
  public static func transcript(conversationID: String, messages: [WorkspaceMessageRecord], runs: [WorkspaceRunRecord],
                                activities: [WorkspaceRunActivityRecord], attachments: [WorkspaceMessageAttachmentRecord],
                                activeRunID: String?, olderCursor: String?,
                                displayedContent: (WorkspaceMessageRecord) -> String = \.content) -> LibraryTranscript {
    let files = Dictionary(grouping: attachments, by: \.messageID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return LibraryTranscript(
      conversationID: conversationID,
      messages: messages.map { message in
        LibraryMessage(id: message.id, conversationID: message.conversationID, runID: message.runID, role: message.role,
          content: displayedContent(message), status: message.status, createdAt: message.createdAt,
          agentSourceID: message.senderSessionID, isAgentAuthored: message.senderSessionID == nil ? nil : true,
          senderSessionTitle: message.senderSessionTitle, senderHarness: message.senderAgent, senderKind: message.senderKind?.rawValue,
          attachments: files[message.id].map { $0.map { LibraryAttachmentReference(id: $0.contentHash ?? $0.id, name: $0.fileName,
            mimeType: $0.mimeType, byteCount: $0.sizeBytes) } })
      },
      activities: activities.map { record in
        LibraryActivity(id: record.id, runID: record.runID, title: record.activity.title ?? record.activity.kind.rawValue,
          detail: record.activity.detail ?? record.activity.content, status: record.activity.status ?? "",
          projectionJSON: (try? encoder.encode(record.activity)).map { String(decoding: $0, as: UTF8.self) },
          sequence: record.sequence, createdAt: record.createdAt.isEmpty ? nil : record.createdAt)
      },
      activeRunID: activeRunID, olderCursor: olderCursor,
      runs: runs.map { LibraryTranscriptRun(id: $0.id, status: $0.status, startedAt: $0.startedAt ?? $0.createdAt,
        completedAt: $0.completedAt, userMessageID: $0.userMessageID, assistantMessageID: $0.assistantMessageID) })
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// A Linux owner splits long text into `<id>-part-<n>` messages of one
  /// input or reply; the view shows each as the one message it is.
  static func joiningParts(_ messages: [LibraryMessage]) -> [LibraryMessage] {
    let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var parts: [String: [(Int, String)]] = [:]
    var absorbed: Set<String> = []
    for message in messages {
      guard let range = message.id.range(of: "-part-", options: .backwards),
            let index = Int(message.id[range.upperBound...]), index > 0 else { continue }
      let base = String(message.id[..<range.lowerBound])
      guard let head = byID[base], head.role == message.role, head.runID == message.runID else { continue }
      parts[base, default: []].append((index, message.content))
      absorbed.insert(message.id)
    }
    guard !absorbed.isEmpty else { return messages }
    return messages.compactMap { message in
      guard !absorbed.contains(message.id) else { return nil }
      guard let tail = parts[message.id] else { return message }
      var joined = message
      joined.content += tail.sorted { $0.0 < $1.0 }.map(\.1).joined()
      return joined
    }
  }
}
