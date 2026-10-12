import Foundation

/// Generation-scoped ownership of OS continuation grants. A grant never starts or resumes work.
/// Kept independent of BackgroundTasks so delayed launch/expiration races can be tested offline.
public struct ContinuedExecutionLedger: Sendable {
  public struct Identity: Equatable, Sendable {
    public let conversationID: String
    public let runID: String
    public let taskIdentifier: String

    public init(conversationID: String, runID: String, taskIdentifier: String) {
      self.conversationID = conversationID
      self.runID = runID
      self.taskIdentifier = taskIdentifier
    }
  }

  public enum Phase: Equatable, Sendable { case requested, active, expiring }
  public struct Entry: Equatable, Sendable {
    public let identity: Identity
    public fileprivate(set) var phase: Phase = .requested
    public fileprivate(set) var completedUnits: Int64 = 0
  }

  private var entries: [String: Entry] = [:]
  public init() {}

  public func entry(conversationID: String) -> Entry? { entries[conversationID] }
  public func entry(taskIdentifier: String) -> Entry? {
    entries.values.first { $0.identity.taskIdentifier == taskIdentifier }
  }

  @discardableResult
  public mutating func request(_ identity: Identity) -> Bool {
    guard entries[identity.conversationID] == nil,
          entry(taskIdentifier: identity.taskIdentifier) == nil else { return false }
    entries[identity.conversationID] = Entry(identity: identity)
    return true
  }

  @discardableResult
  public mutating func activate(_ identity: Identity) -> Bool {
    guard entries[identity.conversationID]?.identity == identity,
          entries[identity.conversationID]?.phase == .requested else { return false }
    entries[identity.conversationID]?.phase = .active
    return true
  }

  /// Only the first expiration notification may interrupt this exact execution generation.
  @discardableResult
  public mutating func expire(_ identity: Identity) -> Bool {
    guard entries[identity.conversationID]?.identity == identity,
          entries[identity.conversationID]?.phase == .active else { return false }
    entries[identity.conversationID]?.phase = .expiring
    return true
  }

  @discardableResult
  public mutating func advance(_ identity: Identity, by units: Int64 = 1) -> Entry? {
    guard units > 0, entries[identity.conversationID]?.identity == identity,
          entries[identity.conversationID]?.phase != .expiring else { return nil }
    let current = entries[identity.conversationID]!.completedUnits
    entries[identity.conversationID]?.completedUnits = current > Int64.max - 1 - units ? Int64.max - 1 : current + units
    return entries[identity.conversationID]
  }

  @discardableResult
  public mutating func finish(_ identity: Identity) -> Entry? {
    guard entries[identity.conversationID]?.identity == identity else { return nil }
    return entries.removeValue(forKey: identity.conversationID)
  }
}
