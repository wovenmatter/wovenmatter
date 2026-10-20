import Foundation

public struct DictationSegment: Sendable, Equatable {
  public var start: Double
  public var end: Double
  public var text: String
  public var isFinal: Bool
  public init(start: Double, end: Double, text: String, isFinal: Bool) {
    self.start = start; self.end = end; self.text = text; self.isFinal = isFinal
  }
}

/// Apple may revise a volatile range or repeat a finalized range. Completion is
/// a lifecycle signal; the text comes from the finalized segments themselves.
public struct DictationTranscript: Sendable {
  private var committed: [DictationSegment] = []
  private var volatile: [DictationSegment] = []
  public init() {}
  public var finalizedText: String { committed.sorted { $0.start < $1.start }.map(\.text).joined() }
  public var preview: String { (committed + volatile).sorted { $0.start < $1.start }.map(\.text).joined() }
  public var hasUnfinalizedText: Bool { volatile.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
  public mutating func update(_ segment: DictationSegment) {
    guard segment.start.isFinite, segment.end.isFinite, segment.end >= segment.start else { return }
    func overlaps(_ other: DictationSegment) -> Bool {
      (other.start == segment.start && other.end == segment.end)
        || (other.start < segment.end && segment.start < other.end)
    }
    volatile.removeAll(where: overlaps)
    if segment.isFinal {
      committed.removeAll(where: overlaps)
      committed.append(segment)
    } else if !committed.contains(where: overlaps) {
      volatile.append(segment)
    }
  }
}

public enum DictationError: LocalizedError, Equatable, Sendable {
  case microphoneDenied, unavailable, unsupportedLanguage, languagePreparation, audioBacklog, incomplete, noSpeech, interrupted
  public var errorDescription: String? {
    switch self {
    case .microphoneDenied: "Microphone access is disabled. Allow microphone access for Woven Matter in system Settings."
    case .unavailable: "On-device dictation is unavailable. Check your microphone and try again."
    case .unsupportedLanguage: "Apple on-device dictation does not support the selected language on this device. Choose another dictation language."
    case .languagePreparation: "Dictation language support could not be prepared. Connect to the internet for the first download, check available storage, and try again."
    case .audioBacklog: "Dictation stopped because audio processing could not keep up with the microphone."
    case .incomplete: "Dictation did not finish. Any completed transcript is available to insert."
    case .noSpeech: "No speech was detected. Try recording again."
    case .interrupted: "Dictation was interrupted. Any completed transcript is available to insert."
    }
  }
}
