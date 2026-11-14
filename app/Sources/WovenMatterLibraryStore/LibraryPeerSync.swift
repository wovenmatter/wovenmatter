import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Glibc)
import Glibc
#endif
import WovenMatterClient
import WovenMatterCore

/// One exchange: the caller pushes its changes after the cursor it last
/// pushed here and asks for this device's changes after `after`.
public struct LibraryPeerExchange: Codable, Sendable {
  public let deviceID: String
  public let after: Int64
  public let page: PairedLibraryPage
  public let version: String
  /// Device-local state a host exchanges alongside rows (a Mac's bearer-era
  /// pairing roster). Opaque here; Linux hosts send none.
  public let attachment: Data?
  public init(deviceID: String, after: Int64, page: PairedLibraryPage, version: String, attachment: Data? = nil) {
    self.deviceID = deviceID; self.after = after; self.page = page; self.version = version; self.attachment = attachment
  }
}

/// "I have new changes up to `cursor`." The receiver pulls when it can.
public struct LibraryPeerNotice: Codable, Sendable {
  public let deviceID: String
  public let cursor: Int64
  public init(deviceID: String, cursor: Int64) { self.deviceID = deviceID; self.cursor = cursor }
}

/// Reply to an exchange in another format (`PairedLibraryFormat.exchange`):
/// both versions, so every device can say which part needs updating.
public struct LibraryPeerUpdateRequired: Codable, Sendable, Equatable {
  public let code: String
  public let message: String
  public let version: String
  public let schema: String
}

public struct LibraryPeerStatus: Codable, Equatable, Sendable, Identifiable {
  public enum State: String, Codable, Sendable { case online, offline, updateRequired, failing }
  public var id: String { deviceID }
  public let deviceID: String
  public let name: String
  public let kind: MemberKind
  public var state: State
  public var version: String?
  public var lastSynchronized: Date?
  public var lastContact: Date?
  public var error: String?
}

/// What the Mac UI and the phone show: each peer's state, and whether some
/// device needs an update before everything can synchronize again.
public struct LibrarySyncStatus: Codable, Equatable, Sendable {
  public let deviceID: String
  public let version: String
  public let schema: String
  public let peers: [LibraryPeerStatus]
  public let conflicts: Int
  public let quarantined: Int
  /// Changes from a newer Woven Matter that this device keeps, relays and
  /// applies once it updates. Absent from a build before it.
  public var waitingForUpdate: Int?
  public var updateRequired: Bool { peers.contains { $0.state == .updateRequired } }
}

/// Sends one signed request to a member endpoint. Production uses URLSession;
/// tests route requests to in-process peers.
public struct LibraryPeerTransport: Sendable {
  public typealias Send = @Sendable (_ endpoint: URL, _ request: LibraryHTTPRequest) async throws -> LibraryHTTPResponse
  public let send: Send
  public init(send: @escaping Send) { self.send = send }

  public static func urlSession() -> LibraryPeerTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration, delegate: RemoteWorkspaceRedirectPolicy.shared, delegateQueue: nil)
    return .init { endpoint, request in
      guard let url = URL(string: request.target, relativeTo: endpoint.rootURL) else { throw URLError(.badURL) }
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = request.method
      urlRequest.httpBody = request.body.isEmpty ? nil : request.body
      for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      guard data.count <= 48 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
      return .init(status: http.statusCode, body: data)
    }
  }
}

private extension URL {
  /// Scheme, host and port only; request targets carry the whole path.
  var rootURL: URL {
    var components = URLComponents(url: self, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.path = "/"; components.query = nil; components.fragment = nil
    return components.url ?? self
  }
}

/// Peer-to-peer library synchronization among every Mac and Linux member
/// (docs/architecture/WOVEN_EVERYWHERE.md, "Library on every surface").
///
/// - A local commit that recorded a new shared version is announced once,
///   debounced, to peers that are online; each pulls with one exchange.
/// - A peer that contacts this device, or that this device reaches again,
///   is caught up once.
/// - A slow presence check (60 s, backing off for offline peers) replaces
///   constant polling.
/// - Every request is a signed member request. Peers must share the exchange
///   format (`PairedLibraryFormat`); a mismatch is reported as "update
///   required". Additions a newer peer has wait here until this device
///   updates, and everything else keeps synchronizing.
public actor LibraryPeerSync {
  /// Optional per-exchange side channel (see `LibraryPeerExchange.attachment`).
  /// `incoming` runs before the page is applied and may throw to refuse it.
  public struct Attachments: Sendable {
    public var outgoing: @Sendable (_ peer: String) async -> Data?
    public var incoming: @Sendable (_ data: Data, _ peer: String) async throws -> Void
    public init(outgoing: @escaping @Sendable (String) async -> Data?, incoming: @escaping @Sendable (Data, String) async throws -> Void) {
      self.outgoing = outgoing; self.incoming = incoming
    }
  }

  public struct Configuration: Sendable {
    public var version: String
    public var presenceInterval: TimeInterval = 60
    public var maximumBackoff: TimeInterval = 900
    public var announceDelay: TimeInterval = 0.3
    public var fileInterval: TimeInterval = 30
    /// Which advertised endpoints this device sends to: tailnet HTTPS only,
    /// as the Node server and the phone require.
    public var allowEndpoint: @Sendable (URL) -> Bool = LibraryPeerSync.isTailnetEndpoint
    public init(version: String) { self.version = version }
  }

  /// `https://<name>.ts.net[:port]/...` with no credentials, query or fragment.
  public static func isTailnetEndpoint(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
          let host = parts.host?.lowercased(), host.hasSuffix(".ts.net"), host.split(separator: ".").count >= 3,
          host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
    return true
  }

  public nonisolated let directory: MemberDirectory
  private let database: WorkspaceDatabase
  private let transport: LibraryPeerTransport
  private let configuration: Configuration
  private let files: PairedLibraryFiles
  private let attachments: Attachments?
  private var statuses: [String: LibraryPeerStatus] = [:]
  private var nextPresence: [String: Date] = [:]
  private var backoff: [String: TimeInterval] = [:]
  private var nextFiles: [String: Date] = [:]
  private var running: Set<String> = []
  /// Peers whose running sync runs once more after, with the latest reason.
  private var again: [String: String] = [:]
  private var announcing: Task<Void, Never>?
  private var presence: Task<Void, Never>?
  private var observer: UUID?
  private var started = false
  /// Peers this device has tried at least once; a newly learned member is
  /// caught up as soon as its entry arrives.
  private var known: Set<String> = []
  private var onChange: (@Sendable () async -> Void)?
  private var lastTick = Date()
  private var networkFingerprint: String?
  private var pathSeen = false
  #if canImport(Network)
  private var pathMonitor: NWPathMonitor?
  #endif
  /// Counts for tests and diagnostics: how each exchange was triggered.
  public private(set) var exchanges: [String: Int] = [:]

  public init(directory: MemberDirectory, transport: LibraryPeerTransport = .urlSession(), configuration: Configuration,
              attachments: Attachments? = nil) {
    self.attachments = attachments
    self.directory = directory; self.database = directory.database
    self.transport = transport; self.configuration = configuration
    files = PairedLibraryFiles(root: directory.database.supportDirectory)
  }

  /// `onChange` runs after rows from a peer were applied (refresh views,
  /// apply member removals to local grants).
  public func start(onChange: (@Sendable () async -> Void)? = nil) {
    guard !started else { return }
    started = true
    self.onChange = onChange
    observer = database.observePeerChanges { [weak self] _ in
      guard let self else { return }
      Task { await self.localChanged() }
    }
    lastTick = Date()
    presence = Task { [weak self] in
      await self?.presenceTick(force: true)
      while !Task.isCancelled {
        guard let interval = await self?.configuration.presenceInterval else { return }
        try? await Task.sleep(for: .seconds(min(interval, 30)))
        await self?.checkResumption()
        await self?.presenceTick(force: false)
      }
    }
    #if canImport(Network)
    // A network change (Wi-Fi to cellular, a VPN coming up) may make every
    // offline peer reachable again; the first update is the current path.
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { await self?.pathChanged(satisfied: satisfied) }
    }
    monitor.start(queue: DispatchQueue(label: "com.wovenmatter.library-sync.path"))
    pathMonitor = monitor
    #endif
  }

  /// Something that may have made peers reachable again (wake from sleep, a
  /// network change): forget every backoff and catch up with each peer once.
  public func resume(reason: String = "wake") async {
    guard started else { return }
    backoff = [:]; nextPresence = [:]
    guard let peers = try? await peers() else { return }
    for member in peers { known.insert(member.deviceID); scheduleSync(member.deviceID, reason: reason) }
  }

  private func pathChanged(satisfied: Bool) async {
    defer { pathSeen = true }
    guard pathSeen, satisfied else { return }
    await resume(reason: "network")
  }

  /// Without system notifications (Linux): a tick that came far later than
  /// scheduled means the machine slept; a change in its interface addresses
  /// means the network changed.
  private func checkResumption() async {
    let now = Date(), expected = min(configuration.presenceInterval, 30)
    defer { lastTick = now }
    let slept = now.timeIntervalSince(lastTick) > expected * 2 + 30
    let fingerprint = Self.interfaceFingerprint()
    let moved = networkFingerprint != nil && fingerprint != networkFingerprint
    networkFingerprint = fingerprint
    if slept || moved { await resume(reason: slept ? "wake" : "network") }
  }

  /// The addresses of the interfaces that are up, sorted; cheap to compare.
  static func interfaceFingerprint() -> String {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return "" }
    defer { freeifaddrs(addresses) }
    var items: [String] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard (entry.ifa_flags & UInt32(IFF_UP)) != 0, let address = entry.ifa_addr else { continue }
      // Container and VM bridges come and go with bots; they are not the network.
      let name = String(cString: entry.ifa_name)
      if ["veth", "docker", "br-", "virbr", "vmnet", "bridge"].contains(where: name.hasPrefix) { continue }
      let family = Int32(address.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
      if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        items.append(name + "=" + String(cString: host))
      }
    }
    return items.sorted().joined(separator: ",")
  }

  public func stop() {
    started = false
    if let observer { database.removePeerChangeObserver(observer) }
    observer = nil
    presence?.cancel(); presence = nil
    announcing?.cancel(); announcing = nil
    #if canImport(Network)
    pathMonitor?.cancel(); pathMonitor = nil
    #endif
  }

  // MARK: Status

  public func status() async -> LibrarySyncStatus {
    let peers = (try? await peers()) ?? []
    var result: [LibraryPeerStatus] = []
    for member in peers {
      var status = statuses[member.deviceID] ?? .init(deviceID: member.deviceID, name: member.name, kind: member.kind, state: .offline)
      status = .init(deviceID: member.deviceID, name: member.name, kind: member.kind, state: status.state, version: status.version,
                     lastSynchronized: status.lastSynchronized, lastContact: status.lastContact, error: status.error)
      result.append(status)
    }
    return .init(deviceID: directory.identity.deviceID, version: configuration.version,
                 schema: (try? await database.pairedLibrarySchema()) ?? "",
                 peers: result,
                 conflicts: (try? await database.peerSyncConflicts().count) ?? 0,
                 quarantined: (try? await database.peerSyncQuarantineCount()) ?? 0,
                 waitingForUpdate: try? await database.peerSyncWaitingForUpdate())
  }

  /// Mac and Linux members other than this device. Phones use the mobile API.
  private func peers() async throws -> [LibraryMember] {
    try await directory.list().members.filter {
      !$0.revoked && $0.deviceID != directory.identity.deviceID && ($0.kind == .mac || $0.kind == .linux)
    }
  }

  private func update(_ member: LibraryMember, _ change: (inout LibraryPeerStatus) -> Void) {
    var status = statuses[member.deviceID] ?? .init(deviceID: member.deviceID, name: member.name, kind: member.kind, state: .offline)
    change(&status)
    statuses[member.deviceID] = status
  }

  // MARK: Triggers

  /// A local commit recorded a new shared version.
  public func localChanged() {
    guard started, announcing == nil else { return }
    let delay = configuration.announceDelay
    announcing = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      await self?.announce()
    }
  }

  private func announce() async {
    announcing = nil
    guard started, let peers = try? await peers() else { return }
    let cursor = (try? await database.peerSyncHead()) ?? 0
    let notice = LibraryPeerNotice(deviceID: directory.identity.deviceID, cursor: cursor)
    await withTaskGroup(of: Void.self) { group in
      for member in peers where statuses[member.deviceID]?.state == .online {
        group.addTask { [weak self] in
          do {
            let response = try await self?.send(member, path: "v1/peers/notify", body: JSONEncoder().encode(notice))
            if let response, response.status != 200 { await self?.failed(member, response) }
          } catch { await self?.offline(member, error) }
        }
      }
    }
  }

  private func presenceTick(force: Bool) async {
    guard started, let peers = try? await peers() else { return }
    let now = Date()
    for member in peers where force || (nextPresence[member.deviceID] ?? .distantPast) <= now {
      known.insert(member.deviceID)
      scheduleSync(member.deviceID, reason: force ? "start" : "presence")
    }
  }

  private func meetNewPeers() async {
    guard started, let peers = try? await peers() else { return }
    for member in peers where !known.contains(member.deviceID) {
      known.insert(member.deviceID)
      scheduleSync(member.deviceID, reason: "joined")
    }
  }

  /// Exchanges with every peer now and returns when done ("Sync now").
  public func synchronizeAll() async {
    guard let peers = try? await peers() else { return }
    for member in peers {
      known.insert(member.deviceID)
      while running.contains(member.deviceID) { try? await Task.sleep(for: .milliseconds(10)) }
      running.insert(member.deviceID)
      exchanges["now", default: 0] += 1
      await synchronize(with: member, includingFiles: true)
      // A notice that arrived meanwhile was queued behind this exchange.
      if let reason = again[member.deviceID], started {
        let id = member.deviceID
        Task { [weak self] in await self?.runSync(id, reason: reason) }
      } else { running.remove(member.deviceID) }
    }
  }

  /// Catches up with every peer once, for example after membership changed.
  public func scheduleAll() async {
    guard started, let peers = try? await peers() else { return }
    for member in peers { known.insert(member.deviceID); scheduleSync(member.deviceID, reason: "members") }
  }

  /// Coalesces: a sync already running for this peer runs once more after.
  public func scheduleSync(_ deviceID: String, reason: String = "request") {
    guard started else { return }
    if running.contains(deviceID) { again[deviceID] = reason; return }
    running.insert(deviceID)
    Task { [weak self] in await self?.runSync(deviceID, reason: reason) }
  }

  private func runSync(_ deviceID: String, reason: String) async {
    var reason = reason
    repeat {
      again[deviceID] = nil
      exchanges[reason, default: 0] += 1
      if let member = try? await peers().first(where: { $0.deviceID == deviceID }) { await synchronize(with: member) }
      if let next = again[deviceID] { reason = next }
    } while again[deviceID] != nil && started
    running.remove(deviceID)
  }

  /// One bounded catch-up with a peer. Public for tests and "Sync now".
  public func synchronize(with member: LibraryMember, includingFiles forceFiles: Bool = false) async {
    var received = false
    do {
      // The first exchange after pairing a large library starts once its
      // recovery backup is written; the peer's reply would be refused before.
      _ = try await database.peerImportsReady()
      let own = directory.identity.deviceID
      for _ in 0..<16 {
        guard await directory.member(member.deviceID) != nil else { return }
        let cursors = try await database.peerSyncCursors(member.deviceID)
        let page = try await database.pairedLibraryPage(after: cursors.pushed)
        let exchange = LibraryPeerExchange(deviceID: own, after: cursors.pulled, page: page, version: configuration.version,
                                           attachment: await attachments?.outgoing(member.deviceID))
        let response = try await send(member, path: "v1/peers/sync", body: JSONEncoder().encode(exchange))
        guard response.status == 200 else { await failed(member, response); return }
        let reply = try JSONDecoder().decode(LibraryPeerExchange.self, from: response.body)
        guard reply.deviceID == member.deviceID, reply.after == page.cursor else {
          throw LibraryAPIError(code: "wrong_peer", message: "The peer did not acknowledge this exact page.")
        }
        if let data = reply.attachment, let attachments { try await attachments.incoming(data, member.deviceID) }
        // A removal learned meanwhile stops the exchange before its page.
        guard await directory.member(member.deviceID) != nil else { return }
        try await database.receivePairedLibrary(reply.page, from: member.deviceID, sender: try await sender(member))
        try await database.acknowledgePairedLibrary(peer: member.deviceID, cursor: page.cursor)
        if !reply.page.entries.isEmpty { received = true; await directory.invalidate(); await meetNewPeers() }
        update(member) { $0.version = reply.version }
        if !page.hasMore && !reply.page.hasMore { break }
      }
      try? await materializePending()
      if forceFiles || received || (nextFiles[member.deviceID] ?? .distantPast) <= Date() {
        do {
          // A manifest longer than one bounded turn continues on the next exchange.
          let finished = try await synchronizeFiles(with: member)
          nextFiles[member.deviceID] = finished ? Date().addingTimeInterval(configuration.fileInterval) : .distantPast
        } catch { update(member) { $0.error = "Files: " + error.localizedDescription } }
      }
      online(member, synchronized: true)
    } catch {
      offline(member, error)
    }
    if received, let onChange { await onChange() }
  }

  /// Returns true when the peer's whole manifest was walked this turn.
  private func synchronizeFiles(with member: LibraryMember) async throws -> Bool {
    var cursor = try await database.peerSyncFileCursor(member.deviceID), chunks = 0
    for _ in 0..<8 {
      // A removal made during a transfer sends no further request.
      guard await directory.member(member.deviceID) != nil else { return true }
      let response = try await send(member, path: "v1/peers/files", body: JSONEncoder().encode(cursor))
      guard response.status == 200 else { throw LibraryAPIError(code: "peer_file", message: "The peer did not list its files.") }
      let page = try JSONDecoder().decode(PairedLibraryFilePage.self, from: response.body)
      for file in page.files where await files.keeps(file) {
        while let offset = try await files.nextOffset(file) {
          guard chunks < 64, !Task.isCancelled else { return false }
          guard await directory.member(member.deviceID) != nil else { return true }
          let reply = try await send(member, path: "v1/peers/file", body: JSONEncoder().encode(PairedLibraryFileRequest(file: file, offset: offset)))
          guard reply.status == 200 else { throw LibraryAPIError(code: "peer_file", message: "The peer did not return a shared file.") }
          let chunk = try JSONDecoder().decode(PairedLibraryFileChunk.self, from: reply.body)
          guard chunk.file == file, chunk.offset == offset else { throw LibraryAPIError(code: "peer_file", message: "Shared file identity changed.") }
          try await files.receive(chunk); chunks += 1
        }
      }
      cursor = page.hasMore ? page.cursor : ""
      try await database.savePeerSyncFileCursor(cursor, peer: member.deviceID)
      if !page.hasMore { try await materializePending(); return true }
    }
    try await materializePending()
    return false
  }

  private func online(_ member: LibraryMember, synchronized: Bool) {
    backoff[member.deviceID] = nil
    nextPresence[member.deviceID] = Date().addingTimeInterval(configuration.presenceInterval)
    update(member) { status in
      if status.state != .updateRequired || synchronized { status.state = .online }
      status.lastContact = Date()
      if synchronized { status.lastSynchronized = Date(); status.error = nil }
    }
  }

  private func offline(_ member: LibraryMember, _ error: any Error) {
    let next = min(configuration.maximumBackoff, max(configuration.presenceInterval, (backoff[member.deviceID] ?? 0) * 2))
    backoff[member.deviceID] = next
    nextPresence[member.deviceID] = Date().addingTimeInterval(next)
    update(member) { status in
      status.state = error is URLError || (error as? LibraryAPIError)?.code == "peer_unavailable" ? .offline : .failing
      status.error = status.state == .offline ? nil : error.localizedDescription
    }
  }

  private func failed(_ member: LibraryMember, _ response: LibraryHTTPResponse) {
    if response.status == 409, let mismatch = try? JSONDecoder().decode(LibraryPeerUpdateRequired.self, from: response.body),
       mismatch.code == "update_required" {
      nextPresence[member.deviceID] = Date().addingTimeInterval(configuration.presenceInterval)
      update(member) { $0.state = .updateRequired; $0.version = mismatch.version; $0.error = mismatch.message; $0.lastContact = Date() }
      return
    }
    let error = (try? JSONDecoder().decode(LibraryAPIError.self, from: response.body))
      ?? LibraryAPIError(code: "peer_sync", message: "The peer refused synchronization (HTTP \(response.status)).")
    offline(member, error)
  }

  /// Applies waiting records whose bytes have arrived, or that an update
  /// made readable, each checked against the member it came from.
  public func materializePending() async throws {
    // Without the member list nothing can be checked; waiting records wait.
    guard let senders = await senders() else { return }
    try await database.materializePendingPeerRecords(senders: senders)
  }

  /// Every current Mac and Linux member as a sender, by device ID; nil when
  /// the member list could not be read.
  private func senders() async -> [String: PairedLibrarySender]? {
    guard let members = try? await peers() else { return nil }
    var result: [String: PairedLibrarySender] = [:]
    for member in members {
      if let sender = try? await sender(member) { result[sender.deviceID] = sender }
    }
    return result
  }

  private func sender(_ member: LibraryMember) async throws -> PairedLibrarySender {
    .init(deviceID: member.deviceID, kind: member.kind, members: try await directory.list().members.map {
      .init(deviceID: $0.deviceID, kind: $0.kind, endpoints: $0.endpoints, revoked: $0.revoked)
    })
  }

  /// Tries each advertised tailnet endpoint in order. The signature covers
  /// the exact target sent to that endpoint (minus any `/wovenmatter` prefix).
  /// An endpoint is self-advertised, so one outside the tailnet is never used.
  private func send(_ member: LibraryMember, path: String, body: Data) async throws -> LibraryHTTPResponse {
    var lastError: (any Error) = LibraryAPIError(code: "peer_unavailable", message: "\(member.name) has no tailnet address yet.")
    for endpoint in member.endpoints where configuration.allowEndpoint(endpoint) {
      var base = endpoint.path
      if !base.hasSuffix("/") { base += "/" }
      let target = base + path
      do {
        var headers = try directory.identity.signer.headers(method: "POST", target: target, body: body, audience: member.deviceID)
        headers["Content-Type"] = "application/json"
        headers["X-Woven-Protocol"] = String(LibraryProtocol.version)
        headers["Host"] = endpoint.host ?? "localhost"
        return try await transport.send(endpoint, .init(method: "POST", target: target, headers: headers, body: body))
      } catch { lastError = error }
    }
    throw lastError
  }

  // MARK: Server

  /// Serves `/v1/peers/sync`, `/v1/peers/notify`, `/v1/peers/files` and
  /// `/v1/peers/file` to signed Mac and Linux members. Returns nil for any
  /// other path or an unsigned request, so later handlers in the chain can answer it.
  public func handle(_ request: LibraryHTTPRequest) async -> LibraryHTTPResponse? {
    let target = MemberRequestSignature.canonicalTarget(request.target)
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    guard ["/v1/peers/sync", "/v1/peers/notify", "/v1/peers/files", "/v1/peers/file"].contains(path),
          MemberRequestVerifier.isSigned(request.headers) else { return nil }
    guard request.method == "POST" else { return .error("method_not_allowed", "Use POST.", status: 405) }
    let member: MemberKey
    do {
      member = try await directory.verifier.verify(method: request.method, target: request.target, headers: request.headers,
                                                   body: request.body, allowing: [.mac, .linux])
    } catch let error as MemberRequestError {
      return .error(error.code, error.message, status: error.code == "wrong_device" ? 403 : 401)
    } catch { return .error("unauthorized", error.localizedDescription, status: 401) }
    guard let resolved = await directory.member(member.deviceID) else { return .error("unauthorized", MemberRequestError.unknown.message, status: 401) }
    // A peer that reaches this device is back: what was announced while it
    // was away never reached it, so catch it up once.
    if started, statuses[resolved.deviceID]?.state != .online || backoff[resolved.deviceID] != nil {
      backoff[resolved.deviceID] = nil; nextPresence[resolved.deviceID] = nil
      if path != "/v1/peers/sync" { scheduleSync(resolved.deviceID, reason: "contact") }
    }
    do {
      switch path {
      case "/v1/peers/notify":
        guard request.body.count <= 1_024 else { return .error("too_large", "Notice too large.", status: 413) }
        let notice = try JSONDecoder().decode(LibraryPeerNotice.self, from: request.body)
        guard notice.deviceID == member.deviceID else { return .error("wrong_peer", "This notice names another device.", status: 403) }
        online(resolved, synchronized: false)
        let pulled = try await database.peerSyncCursors(member.deviceID).pulled
        if notice.cursor > pulled { scheduleSync(member.deviceID, reason: "notice") }
        return try .json(["accepted": true])
      case "/v1/peers/sync":
        guard request.body.count <= 48 * 1_024 * 1_024 else { return .error("too_large", "Page too large.", status: 413) }
        let exchange = try JSONDecoder().decode(LibraryPeerExchange.self, from: request.body)
        guard exchange.deviceID == member.deviceID, exchange.after >= 0 else {
          return .error("wrong_peer", "This exchange names another device.", status: 403)
        }
        guard exchange.page.format == PairedLibraryFormat.exchange else {
          let schema = try await database.pairedLibrarySchema()
          update(resolved) { $0.state = .updateRequired; $0.version = exchange.version; $0.lastContact = Date()
            $0.error = "\(resolved.name) runs Woven Matter \(exchange.version); this device runs \(self.configuration.version). Update everything to synchronize." }
          return try .json(LibraryPeerUpdateRequired(code: "update_required",
            message: "Update Woven Matter on every device: this device runs \(configuration.version), \(resolved.name) runs \(exchange.version).",
            version: configuration.version, schema: schema), status: 409)
        }
        // While this library's recovery backup is still being written, the
        // caller retries later; this device's own exchange with it follows
        // the backup, so neither side waits for the caller's backoff.
        guard try await database.peerImportsReady(timeout: 5) else {
          scheduleSync(member.deviceID, reason: "backup")
          let refusal = WorkspaceDatabase.peerBackupPending
          return .error(refusal.code, refusal.message, status: 503)
        }
        if let data = exchange.attachment, let attachments { try await attachments.incoming(data, member.deviceID) }
        try await database.receivePairedLibrary(exchange.page, from: member.deviceID, sender: try await sender(resolved))
        // A removal learned in this page ends access before anything returns.
        await directory.invalidate()
        if !exchange.page.entries.isEmpty { await meetNewPeers() }
        guard await directory.member(member.deviceID) != nil else { return .error("unauthorized", "This device was removed.", status: 401) }
        // `after` is the caller's committed receive cursor for this device: it
        // already holds everything up to there, so this device's own pushes to
        // it resume after that point instead of resending it.
        try await database.acknowledgePairedLibrary(peer: member.deviceID, cursor: exchange.after)
        let reply = LibraryPeerExchange(deviceID: directory.identity.deviceID, after: exchange.page.cursor,
          page: try await database.pairedLibraryPage(after: exchange.after), version: configuration.version,
          attachment: await attachments?.outgoing(member.deviceID))
        // The reply already carries this device's changes; the caller keeps
        // exchanging until neither side has more.
        online(resolved, synchronized: true)
        update(resolved) { $0.version = exchange.version }
        if !exchange.page.entries.isEmpty, let onChange { Task { await onChange() } }
        return try .json(reply)
      case "/v1/peers/files":
        guard request.body.count <= 4_096 else { return .error("too_large", "Cursor too large.", status: 413) }
        return try .json(try await files.page(after: JSONDecoder().decode(String.self, from: request.body)))
      default:
        guard request.body.count <= 4_096 else { return .error("too_large", "Request too large.", status: 413) }
        return try .json(try await files.chunk(JSONDecoder().decode(PairedLibraryFileRequest.self, from: request.body)))
      }
    } catch let error as LibraryAPIError {
      return .error(error.code, error.message, status: error.code == "unauthorized" ? 401 : 409)
    } catch {
      return .error("peer_sync", "Synchronization paused; all local writing is retained. " + error.localizedDescription, status: 409)
    }
  }
}
