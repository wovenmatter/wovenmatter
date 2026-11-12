import Foundation
import WovenMatterShared

/// A message this device sent to a Mac or Linux workspace that the
/// workspace's transcript does not show yet. The chat shows it at once, with
/// progress, until the transcript shows it and the turn it started; a send
/// that fails removes it and puts the text back in the composer.
public struct PendingSend: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Waiting for the workspace to accept the message.
    case sending
    /// Accepted; waiting for the transcript to show it and its turn.
    case starting
  }
  public var id: String
  public var text: String
  public var phase: Phase
  public var sentAt: Date
  /// User messages the transcript held when this was sent. The next one is this message.
  public var baseline: Int
  /// How long an accepted message waits for its turn before the chat stops showing progress.
  public static let timeout: TimeInterval = 120

  public init(id: String = UUID().uuidString.lowercased(), text: String, transcript: LibraryTranscript?, sentAt: Date = Date()) {
    self.id = id; self.text = text; phase = .sending; self.sentAt = sentAt
    baseline = Self.userMessages(transcript).count
  }

  static func userMessages(_ transcript: LibraryTranscript?) -> [LibraryMessage] {
    transcript?.messages.filter { $0.role == "user" } ?? []
  }
  /// The transcript shows this message.
  public func isShown(in transcript: LibraryTranscript?) -> Bool {
    Self.userMessages(transcript).count > baseline
  }
  /// The transcript shows this message and the turn it started: a running
  /// run, or a reply, activity or run after it.
  public func hasStarted(in transcript: LibraryTranscript?) -> Bool {
    guard let transcript, isShown(in: transcript) else { return false }
    if transcript.activeRunID != nil { return true }
    let message = Self.userMessages(transcript)[baseline]
    if let index = transcript.messages.firstIndex(where: { $0.id == message.id }),
       transcript.messages[transcript.messages.index(after: index)...].contains(where: { $0.role != "user" }) { return true }
    guard let runID = message.runID else { return false }
    return transcript.runs?.contains { $0.id == runID } == true || transcript.activities.contains { $0.runID == runID }
  }
  /// Nothing more to show: the turn started, or an accepted message waited past `timeout`.
  public func isFinished(in transcript: LibraryTranscript?, now: Date = Date()) -> Bool {
    hasStarted(in: transcript) || (phase == .starting && now.timeIntervalSince(sentAt) > Self.timeout)
  }
  /// The transcript to show: the workspace's, with this message after it until the workspace shows it.
  public func displayed(in transcript: LibraryTranscript?, conversationID: String) -> LibraryTranscript {
    var value = transcript ?? .init(conversationID: conversationID)
    guard !isShown(in: transcript) else { return value }
    value.messages.append(.init(id: "pending-send:" + id, conversationID: value.conversationID, role: "user",
      content: text, status: "sending"))
    return value
  }
}
