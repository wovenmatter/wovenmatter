import Foundation
import WovenMatterCore

/// Every long-lived socket a member holds on this server (stream sockets and
/// `/v1/bots/ws` relays), by member device ID. When the member list changes,
/// each socket whose member was removed, or is no longer a kind its route
/// allows, is closed: a stream socket with close code 4401, a relay by closing
/// its connection.
public actor MemberSocketRegistry {
  public struct Owner: Sendable {
    public let registry: MemberSocketRegistry
    public let deviceID: String
    /// The member kinds the socket's route allows.
    public let kinds: Set<MemberKind>
    public init(registry: MemberSocketRegistry, deviceID: String, kinds: Set<MemberKind>) {
      self.registry = registry; self.deviceID = deviceID.lowercased(); self.kinds = kinds
    }
  }
  private struct Entry {
    let deviceID: String
    let kinds: Set<MemberKind>
    let close: @Sendable () -> Void
  }
  private let members: MemberDirectory
  private var entries: [UUID: Entry] = [:]
  private var observer: UUID?
  private var sweeping = false
  private var sweepAgain = false

  public init(members: MemberDirectory) { self.members = members }

  /// Starts closing revoked sockets whenever the member list changes.
  public func start() async {
    guard observer == nil else { return }
    observer = await members.observeChanges { [weak self] in
      guard let self else { return }
      Task { await self.revalidate() }
    }
  }

  public func stop() async {
    if let observer { await members.removeObserver(observer) }
    observer = nil
  }

  /// Keeps a socket whose member was authenticated when it opened. A removal
  /// between that check and this registration was swept without it, so the
  /// member is checked once more here, and the socket closed if it is gone.
  @discardableResult
  public func register(deviceID: String, kinds: Set<MemberKind>, close: @escaping @Sendable () -> Void) async -> UUID {
    let id = UUID(), entry = Entry(deviceID: deviceID.lowercased(), kinds: kinds, close: close)
    entries[id] = entry
    // As in a sweep, a list that cannot be read closes nothing.
    if let list = try? await members.list(), entries[id] != nil,
       !(list.active(entry.deviceID).map { kinds.contains($0.kind) } ?? false) {
      entries.removeValue(forKey: id)
      close()
    }
    return id
  }

  public func unregister(_ id: UUID) { entries.removeValue(forKey: id) }

  /// Open sockets by member device ID.
  public func openSockets() -> [String: Int] {
    entries.values.reduce(into: [:]) { $0[$1.deviceID, default: 0] += 1 }
  }

  /// Closes every socket whose member is no longer current or allowed there.
  /// Returns how many it closed.
  @discardableResult
  public func revalidate() async -> Int {
    // A change during a sweep is checked by one more sweep after it.
    guard !sweeping else { sweepAgain = true; return 0 }
    sweeping = true
    defer { sweeping = false }
    var closed = 0
    repeat {
      sweepAgain = false
      // A list that cannot be read closes nothing: 4401 tells a client not
      // to retry, so only a list that names the change may cause it.
      guard let list = try? await members.list() else { return closed }
      for (id, entry) in entries {
        if let member = list.active(entry.deviceID), entry.kinds.contains(member.kind) { continue }
        entries.removeValue(forKey: id)
        entry.close()
        closed += 1
      }
    } while sweepAgain
    return closed
  }
}
