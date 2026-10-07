import Foundation

extension AgentRunActivity {
  /// A bounded read model, never a replacement for the captured activity.
  /// Commentary checkpoints require their complete segment text.
  public func presentationSummary(version: Int64? = nil) -> Self {
    let preview: String?
    switch kind {
    case .assistant, .plan, .fileChange: preview = content
    default: preview = content.map { String($0.prefix(280)) }
    }
    return Self(id: id, kind: kind, phase: phase,
      title: title.map { String($0.prefix(280)) },
      detail: detail.map { String($0.prefix(280)) }, status: status, toolName: toolName,
      content: preview, contentIsDelta: contentIsDelta,
      assistantMessageID: assistantMessageID, assistantCheckpoint: assistantCheckpoint,
      position: position, locations: locations, changes: changes, planEntries: planEntries,
      subagents: nil,
      detailsAvailable: detailsAvailable == true || rawInputJSON != nil || rawOutputJSON != nil
        || rawPayloadJSON != nil || subagents?.isEmpty == false || preview != content,
      detailVersion: version ?? detailVersion)
  }
}
