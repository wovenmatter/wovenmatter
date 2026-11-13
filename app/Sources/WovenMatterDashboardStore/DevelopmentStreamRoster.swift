import Foundation
import WovenMatterCore

/// The stream keys of client-mode Dev builds on this Mac, admitted by this
/// live library host over its same-user Unix socket (`development.connect`,
/// `development.stream`) and accepted only by its loopback development stream
/// listener (docs/DEVELOPMENT_BUILDS.md, "Client mode").
///
/// A Dev key is not a library member. The roster lives in this process's
/// memory only: it is never written to SQLite, the signed member list, a
/// file, or anything another device synchronizes, so no other device ever
/// learns a Dev key. A stopped host forgets every entry, and each Dev client
/// admits its key again, authenticated by its current Dev device credential,
/// before every stream attempt.
public actor DevelopmentStreamRoster {
  public struct Entry: Sendable, Equatable {
    public let deviceID: String
    public let name: String
    public let publicKey: Data
  }

  /// Why an entry left the roster: the observer closes that device's sockets
  /// with 4401 when it was revoked, and with 1001 when another key replaced it.
  public enum Removal: Sendable, Equatable { case revoked, replaced }

  /// Verifies upgrades signed by roster keys only, addressed to this host's
  /// member device ID.
  public nonisolated let verifier: MemberRequestVerifier
  public nonisolated let audience: String
  private var entries: [String: Entry] = [:]
  private var observers: [UUID: @Sendable (String, Removal) -> Void] = [:]

  public init(audience: String) {
    self.audience = audience.lowercased()
    let box = WeakRoster()
    verifier = MemberRequestVerifier(audience: audience, lookup: { await box.roster?.key($0) },
      verify: { MemberIdentity.verify(publicKey: $0, signature: $1, message: $2) })
    box.roster = self
  }
  private final class WeakRoster: @unchecked Sendable { weak var roster: DevelopmentStreamRoster? }

  /// Admits (or keeps) `publicKey` for one Dev device. The caller has already
  /// authenticated that device's current Dev credential on the same-user
  /// socket and checked that the ID is not a real member's.
  public func admit(deviceID: String, name: String, publicKey: Data) throws {
    let id = deviceID.lowercased()
    guard MemberRequestSignature.isDeviceID(id), id != audience, publicKey.count == 32 else {
      throw LibraryAPIError(code: "invalid_device", message: "Invalid development stream key.")
    }
    if let current = entries[id], current.publicKey == publicKey { return }
    let replaced = entries[id] != nil
    entries[id] = .init(deviceID: id, name: name, publicKey: publicKey)
    if replaced { notify(id, .replaced) }
  }

  /// Removes a device's key and closes its sockets with 4401.
  public func revoke(_ deviceID: String) {
    let id = deviceID.lowercased()
    guard entries.removeValue(forKey: id) != nil else { return }
    notify(id, .revoked)
  }

  /// Forgets every key without closing anything: the stream itself is stopping.
  public func clear() { entries.removeAll() }

  public func entry(_ deviceID: String) -> Entry? { entries[deviceID.lowercased()] }
  public var deviceIDs: Set<String> { Set(entries.keys) }

  private func key(_ deviceID: String) -> MemberKey? {
    entries[deviceID].map { .init(deviceID: $0.deviceID, kind: .mac, name: $0.name, publicKey: $0.publicKey) }
  }

  /// The roster entry that signed `request`, as the stream's member. Its kind
  /// is `mac`; it is in no member list, so a member list change never closes
  /// its socket and its stream cannot send commands (`execution.command`
  /// checks the member list).
  public func authenticate(_ request: LibraryHTTPRequest) async throws -> LibraryMember {
    let key = try await verifier.verify(method: request.method, target: request.target, headers: request.headers,
                                        body: request.body, allowing: [.mac])
    guard let entry = entries[key.deviceID], entry.publicKey == key.publicKey else { throw MemberRequestError.unknown }
    return LibraryMember(deviceID: entry.deviceID, kind: .mac, name: entry.name, publicKey: entry.publicKey,
                         endpoints: [], addedBy: audience, revoked: false)
  }

  @discardableResult
  public func observeRemovals(_ handler: @escaping @Sendable (String, Removal) -> Void) -> UUID {
    let id = UUID(); observers[id] = handler; return id
  }

  private func notify(_ deviceID: String, _ removal: Removal) {
    for observer in observers.values { observer(deviceID, removal) }
  }
}
