/// Reassembles a native replacement before exposing it to cumulative-text
/// admission fences. A truncated replacement never becomes a partial reply.
public struct NativeTextSnapshotAssembler: Sendable {
  private var pending: String?
  public init() {}
  public mutating func reset() { pending = nil }
  public mutating func receive(_ text: String, starts: Bool, ends: Bool) -> String? {
    if starts { pending = text }
    else if let pending { self.pending = pending + text }
    else { return nil }
    guard ends else { return nil }
    let result = pending
    pending = nil
    return result
  }
}
