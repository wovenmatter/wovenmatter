import Foundation

extension AgentRunActivity {
  /// A bounded read model, never a replacement for the captured activity.
  /// Commentary checkpoints require their complete segment text.
  /// Database workers call this off the main actor, including for old cached
  /// summaries. File counts are computed together before their bodies are dropped.
  public func presentationSummary(version: Int64? = nil) -> Self {
    let preview: String?
    switch kind {
    case .assistant, .plan: preview = content
    default: preview = content.map { String($0.prefix(280)) }
    }
    return Self(id: id, kind: kind, phase: phase,
      title: title.map { String($0.prefix(280)) },
      detail: detail.map { String($0.prefix(280)) }, status: status, toolName: toolName,
      content: preview, contentIsDelta: contentIsDelta,
      assistantMessageID: assistantMessageID, assistantCheckpoint: assistantCheckpoint,
      position: position, locations: locations, changes: changes.map { $0.presentationSummary() }, planEntries: planEntries,
      subagents: nil,
      detailsAvailable: detailsAvailable == true || rawInputJSON != nil || rawOutputJSON != nil
        || rawPayloadJSON != nil || subagents?.isEmpty == false || !changes.isEmpty || preview != content
        || title.map { String($0.prefix(280)) } != title
        || detail.map { String($0.prefix(280)) } != detail,
      detailVersion: version ?? detailVersion,
      planKind: planKind, planOperation: planOperation)
  }
}

private extension AgentRunFileChange {
  func presentationSummary() -> Self {
    let counts = changedLineCounts
    return Self(path: path, newText: "", additionCount: counts.additions, deletionCount: counts.deletions)
  }
}
