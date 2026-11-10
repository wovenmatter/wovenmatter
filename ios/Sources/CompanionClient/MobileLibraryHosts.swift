import Foundation
import WovenMatterCompanion

/// One Mac or Linux member that serves the mobile library API.
public struct MobileLibraryHost: Codable, Equatable, Sendable, Identifiable {
  public var id: String { deviceID }
  public var deviceID: String
  public var kind: String
  public var name: String
  public var endpoint: URL
  public init(deviceID: String, kind: String, name: String, endpoint: URL) {
    self.deviceID = deviceID.lowercased(); self.kind = kind; self.name = name; self.endpoint = endpoint
  }
}

/// What the phone knows about its membership: where it paired, the member
/// list it last learned (from whichever host it synced with), which host it
/// last used, and whether that host accepted member signatures.
public struct MobileMembershipState: Codable, Equatable, Sendable {
  public var formatVersion = 1
  public var deviceID: String
  /// The Mac the phone paired with. Only a starting point: it is never required.
  public var pairedEndpoint: URL
  public var pairedHostDeviceID: String?
  public var pairedName: String?
  public var members: [MobileLibraryMember] = []
  public var membersRevision: String?
  /// The last host a synchronization succeeded with; tried first next time.
  public var preferredHostDeviceID: String?
  public var currentHost: MobileLibraryHost?
  /// False once the paired Mac answered that it does not accept member
  /// requests; the phone then keeps its bearer grant and says "Update everything".
  public var memberRequestsAccepted: Bool?
  public var syncStatus: MobileLibrarySyncStatus?
  public var updatedAt: Date?
  public init(deviceID: String, pairedEndpoint: URL, pairedHostDeviceID: String? = nil, pairedName: String? = nil) {
    self.deviceID = deviceID.lowercased(); self.pairedEndpoint = pairedEndpoint
    self.pairedHostDeviceID = pairedHostDeviceID?.lowercased(); self.pairedName = pairedName
  }

  /// The tailnet a host must be on: the paired endpoint's `<tailnet>.ts.net`.
  /// Endpoints learned from synced records never leave it.
  var tailnetSuffix: String? {
    guard let host = pairedEndpoint.host?.lowercased(), host.hasSuffix(".ts.net") else { return nil }
    let labels = host.split(separator: ".")
    guard labels.count >= 4 else { return nil }
    return labels.suffix(3).joined(separator: ".")
  }

  /// A member endpoint as the mobile API's base URL (`https://host/wovenmatter`).
  static func libraryEndpoint(_ url: URL, tailnet: String?) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme == "https", let host = components.host?.lowercased() else { return nil }
    if let tailnet { guard host.hasSuffix("." + tailnet) else { return nil } }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    guard path.isEmpty || path == "/wovenmatter" else { return nil }
    components.path = "/wovenmatter"
    guard let value = components.url, CompanionPairingPayload.isValidEndpoint(value) else { return nil }
    return value
  }

  /// Every Mac and Linux host to try, best first: the last one that worked,
  /// then the paired Mac, other Macs, then Linux hosts. A Mac without a member
  /// endpoint is reached at its registered execution workspace address, which
  /// is the same server.
  public func candidates(registry: [CompanionExecutionWorkspace] = []) -> [MobileLibraryHost] {
    var result: [MobileLibraryHost] = []
    func add(_ host: MobileLibraryHost) {
      guard host.deviceID != deviceID, !result.contains(where: { $0.deviceID == host.deviceID || $0.endpoint == host.endpoint }) else { return }
      result.append(host)
    }
    let active = members.filter { !$0.revoked && ($0.kind == "mac" || $0.kind == "linux") && $0.deviceID != deviceID }
    var hosts: [MobileLibraryHost] = []
    for member in active {
      let advertised = member.endpoints.lazy.compactMap { Self.libraryEndpoint($0, tailnet: tailnetSuffix) }.first
      let registered = member.kind == "mac" ? registry.first(where: {
        $0.kind == .mac && !$0.deleted && $0.ownerDeviceID.lowercased() == member.deviceID && $0.endpoint != nil
      })?.endpoint.flatMap { Self.libraryEndpoint($0, tailnet: tailnetSuffix) } : nil
      if let endpoint = advertised ?? registered {
        hosts.append(.init(deviceID: member.deviceID, kind: member.kind, name: member.name, endpoint: endpoint))
      }
    }
    if let preferred = preferredHostDeviceID {
      if let host = hosts.first(where: { $0.deviceID == preferred }) { add(host) }
      else if let current = currentHost, current.deviceID == preferred,
              !members.contains(where: { $0.deviceID == preferred && $0.revoked }) { add(current) }
    }
    if let paired = pairedHostDeviceID, let host = hosts.first(where: { $0.deviceID == paired }) { add(host) }
    else if !members.contains(where: { $0.deviceID == pairedHostDeviceID && $0.revoked }) {
      add(.init(deviceID: pairedHostDeviceID ?? "paired", kind: "mac", name: pairedName ?? "Paired Mac", endpoint: pairedEndpoint))
    }
    for host in hosts.filter({ $0.kind == "mac" }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { add(host) }
    for host in hosts.filter({ $0.kind == "linux" }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { add(host) }
    return result
  }
}

/// The persisted membership and host choice. Endpoints are not secrets; the
/// signing key stays in the Keychain.
public actor MobileLibraryHosts {
  public nonisolated let identity: MobileMemberIdentity
  private let file: URL?
  private let metadata: CompanionDeviceMetadata?
  private let performer: (any MobileHTTPPerforming)?
  private var state: MobileMembershipState

  public init(state: MobileMembershipState, identity: MobileMemberIdentity, file: URL?, metadata: CompanionDeviceMetadata? = nil,
              performer: (any MobileHTTPPerforming)? = nil) throws {
    self.state = state; self.identity = identity; self.file = file; self.metadata = metadata; self.performer = performer
    try Self.persist(state, to: file)
  }

  public static func load(file: URL) throws -> MobileMembershipState? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try JSONDecoder().decode(MobileMembershipState.self, from: Data(contentsOf: file))
  }
  public static func clear(file: URL) throws {
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
  }
  private static func persist(_ state: MobileMembershipState, to file: URL?) throws {
    guard let file else { return }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func update(_ change: (inout MobileMembershipState) -> Void) {
    var next = state; change(&next)
    guard next != state else { return }
    next.updatedAt = Date()
    state = next
    try? Self.persist(next, to: file)
  }

  public func snapshot() -> MobileMembershipState { state }
  public func transport(for host: MobileLibraryHost) throws -> HTTPSCompanionTransport {
    try HTTPSCompanionTransport(host: host.endpoint, hostDeviceID: host.deviceID, identity: identity, metadata: metadata, performer: performer)
  }

  /// Chooses a reachable host, trying candidates in order and failing over
  /// automatically. Each attempt is one short hello; nothing polls. A host that
  /// does not know this phone yet (it has not synced with the Mac that added
  /// it) or is too old is skipped like an offline one.
  public func connect(registry: [CompanionExecutionWorkspace]) async throws -> (HTTPSCompanionTransport, CompanionHello, MobileLibraryHost) {
    var failures: [any Error] = []
    for host in state.candidates(registry: registry) {
      try Task.checkCancellation()
      do {
        let transport = try transport(for: host)
        let hello = try await transport.probe()
        update { next in
          next.preferredHostDeviceID = host.deviceID; next.currentHost = host
          if host.endpoint == next.pairedEndpoint || host.deviceID == next.pairedHostDeviceID { next.memberRequestsAccepted = true }
        }
        return (transport, hello, host)
      } catch {
        if error is CancellationError { throw error }
        if case MobileConnectionError.memberUnsupported = error, host.endpoint == state.pairedEndpoint || host.deviceID == state.pairedHostDeviceID {
          update { $0.memberRequestsAccepted = false }
        }
        failures.append(error)
      }
    }
    update { $0.currentHost = nil }
    throw Self.summary(failures)
  }

  /// The error that best explains why no host answered.
  static func summary(_ failures: [any Error]) -> any Error {
    if let update = failures.first(where: { if case MobileConnectionError.updateRequired = $0 { true } else { false } }) { return update }
    if !failures.isEmpty, failures.allSatisfy({ if case MobileConnectionError.memberUnknown = $0 { true } else { false } }) {
      return MobileConnectionError.memberUnknown
    }
    if failures.contains(where: { if case MobileConnectionError.memberUnsupported = $0 { true } else { false } }),
       !failures.contains(where: { $0 is URLError }) { return MobileConnectionError.memberUnsupported }
    return failures.first(where: { $0 is URLError }) ?? failures.first ?? MobileConnectionError.offline
  }

  /// Learns the member list (with endpoints) and the sync status from the host
  /// it just synced with. Bounded and change-free when nothing moved.
  public func learn(from transport: HTTPSCompanionTransport, host: MobileLibraryHost) async {
    // The host's library identity names its member device ID.
    if let identity = try? await transport.libraryIdentity() {
      let real = identity.hostDeviceID.lowercased()
      update { next in
        if Self.sameBase(host.endpoint, next.pairedEndpoint) { next.pairedHostDeviceID = real }
        if next.preferredHostDeviceID == host.deviceID { next.preferredHostDeviceID = real }
        if next.currentHost?.deviceID == host.deviceID { next.currentHost?.deviceID = real }
      }
    }
    if let list = try? await transport.members() {
      update { next in
        next.members = list.members
        next.membersRevision = list.revision
        if let current = next.currentHost, let member = list.members.first(where: { $0.deviceID == current.deviceID }) {
          next.currentHost?.name = member.name
          if next.pairedHostDeviceID == current.deviceID { next.pairedName = member.name }
        }
      }
    }
    await refreshSyncStatus(from: transport)
  }
  /// The host the phone currently syncs with, by member device ID.
  public func currentHostDeviceID() -> String? { state.currentHost?.deviceID }
  public func refreshSyncStatus(from transport: HTTPSCompanionTransport) async {
    if let status = try? await transport.syncStatus() { update { $0.syncStatus = status } }
  }
  public func setPairedHost(deviceID: String?, name: String?) {
    update { next in
      if let deviceID { next.pairedHostDeviceID = deviceID.lowercased() }
      if let name { next.pairedName = name }
    }
  }
  public func markMemberRequests(accepted: Bool) { update { $0.memberRequestsAccepted = accepted } }

  static func sameBase(_ lhs: URL, _ rhs: URL) -> Bool {
    MobileMembershipState.libraryEndpoint(lhs, tailnet: nil) == MobileMembershipState.libraryEndpoint(rhs, tailnet: nil)
  }
}
