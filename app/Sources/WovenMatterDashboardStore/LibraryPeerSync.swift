import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
  public init(deviceID: String, after: Int64, page: PairedLibraryPage, version: String) {
    self.deviceID = deviceID; self.after = after; self.page = page; self.version = version
  }
}

/// "I have new changes up to `cursor`." The receiver pulls when it can.
public struct LibraryPeerNotice: Codable, Sendable {
  public let deviceID: String
  public let cursor: Int64
  public init(deviceID: String, cursor: Int64) { self.deviceID = deviceID; self.cursor = cursor }
}

/// Reply to an exchange whose shared schema differs: both versions, so every
/// device can say which part needs updating.
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
  public var updateRequired: Bool { peers.contains { $0.state == .updateRequired } }
}

/// Sends one signed request to a member endpoint. Production uses URLSession;
/// tests route requests to in-process peers.
public struct LibraryPeerTransport: Sendable {
  public typealias Send = @Sendable (_ endpoint: URL, _ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse
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
/// - A local commit that appended to the change log is announced once,
///   debounced, to peers that are online; each pulls with one exchange.
/// - A peer that contacts this device, or that this device reaches again,
///   is caught up once.
/// - A slow presence check (60 s, backing off for offline peers) replaces
///   constant polling.
/// - Every request is a signed member request; peers must share the exact
///   shared-table schema, and a mismatch is reported as "update required".
public actor LibraryPeerSync {
  public struct Configuration: Sendable {
    public var version: String
    public var presenceInterval: TimeInterval = 60
    public var maximumBackoff: TimeInterval = 900
    public var announceDelay: TimeInterval = 0.3
    public var fileInterval: TimeInterval = 30
    public init(version: String) { self.version = version }
  }

  public nonisolated let directory: MemberDirectory
  private let database: WorkspaceDatabase
  private let transport: LibraryPeerTransport
  private let configuration: Configuration
  private let files: PairedLibraryFiles
  private var statuses: [String: LibraryPeerStatus] = [:]
  private var nextPresence: [String: Date] = [:]
  private var backoff: [String: TimeInterval] = [:]
  private var nextFiles: [String: Date] = [:]
  private var running: Set<String> = []
  private var again: Set<String> = []
  private var announcing: Task<Void, Never>?
  private var presence: Task<Void, Never>?
  private var observer: UUID?
  private var started = false
  /// Peers this device has tried at least once; a newly learned member is
  /// caught up as soon as its entry arrives.
  private var known: Set<String> = []
  private var onChange: (@Sendable () async -> Void)?
  /// Counts for tests and diagnostics: how each exchange was triggered.
  public private(set) var exchanges: [String: Int] = [:]

  public init(directory: MemberDirectory, transport: LibraryPeerTransport = .urlSession(), configuration: Configuration) {
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
    presence = Task { [weak self] in
      await self?.presenceTick(force: true)
      while !Task.isCancelled {
        guard let interval = await self?.configuration.presenceInterval else { return }
        try? await Task.sleep(for: .seconds(min(interval, 30)))
        await self?.presenceTick(force: false)
      }
    }
  }

  public func stop() {
    started = false
    if let observer { database.removePeerChangeObserver(observer) }
    observer = nil
    presence?.cancel(); presence = nil
    announcing?.cancel(); announcing = nil
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
                 conflicts: (try? await database.pairedLibraryConflicts().count) ?? 0,
                 quarantined: (try? await database.pairedLibraryQuarantineCount()) ?? 0)
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

  /// A local commit appended to the change log.
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
    let cursor = (try? await database.pairedLibraryHead()) ?? 0
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

  /// Catches up with every peer once, for example after membership changed.
  public func scheduleAll() async {
    guard started, let peers = try? await peers() else { return }
    for member in peers { known.insert(member.deviceID); scheduleSync(member.deviceID, reason: "members") }
  }

  /// Coalesces: a sync already running for this peer runs once more after.
  public func scheduleSync(_ deviceID: String, reason: String = "request") {
    guard started else { return }
    if running.contains(deviceID) { again.insert(deviceID); return }
    running.insert(deviceID)
    Task { [weak self] in await self?.runSync(deviceID, reason: reason) }
  }

  private func runSync(_ deviceID: String, reason: String) async {
    repeat {
      again.remove(deviceID)
      exchanges[reason, default: 0] += 1
      if let member = try? await peers().first(where: { $0.deviceID == deviceID }) { await synchronize(with: member) }
    } while again.contains(deviceID) && started
    running.remove(deviceID)
  }

  /// One bounded catch-up with a peer. Public for tests and "Sync now".
  public func synchronize(with member: LibraryMember) async {
    var received = false
    do {
      let own = directory.identity.deviceID
      for _ in 0..<16 {
        guard await directory.member(member.deviceID) != nil else { return }
        let cursors = try await database.pairedLibraryCursors(member.deviceID)
        let page = try await database.pairedLibraryPage(after: cursors.pushed)
        let exchange = LibraryPeerExchange(deviceID: own, after: cursors.pulled, page: page, version: configuration.version)
        let response = try await send(member, path: "v1/peers/sync", body: JSONEncoder().encode(exchange))
        guard response.status == 200 else { await failed(member, response); return }
        let reply = try JSONDecoder().decode(LibraryPeerExchange.self, from: response.body)
        guard reply.deviceID == member.deviceID, reply.after == page.cursor else {
          throw CompanionAPIError(code: "wrong_peer", message: "The peer did not acknowledge this exact page.")
        }
        // A removal learned meanwhile stops the exchange before its page.
        guard await directory.member(member.deviceID) != nil else { return }
        try await database.receivePairedLibrary(reply.page, from: member.deviceID)
        try await database.acknowledgePairedLibrary(peer: member.deviceID, cursor: page.cursor)
        if !reply.page.entries.isEmpty { received = true; await directory.invalidate(); await meetNewPeers() }
        update(member) { $0.version = reply.version }
        if !page.hasMore && !reply.page.hasMore { break }
      }
      try? await database.materializePendingPeerRecords()
      if received || (nextFiles[member.deviceID] ?? .distantPast) <= Date() {
        do { try await synchronizeFiles(with: member); nextFiles[member.deviceID] = Date().addingTimeInterval(configuration.fileInterval) }
        catch { update(member) { $0.error = "Files: " + error.localizedDescription } }
      }
      online(member, synchronized: true)
    } catch {
      offline(member, error)
    }
    if received, let onChange { await onChange() }
  }

  private func synchronizeFiles(with member: LibraryMember) async throws {
    var cursor = try await database.pairedLibraryFileCursor(member.deviceID), chunks = 0
    for _ in 0..<8 {
      let response = try await send(member, path: "v1/peers/files", body: JSONEncoder().encode(cursor))
      guard response.status == 200 else { throw CompanionAPIError(code: "peer_file", message: "The peer did not list its files.") }
      let page = try JSONDecoder().decode(PairedLibraryFilePage.self, from: response.body)
      for file in page.files {
        while let offset = try await files.nextOffset(file) {
          guard chunks < 64, !Task.isCancelled else { return }
          let reply = try await send(member, path: "v1/peers/file", body: JSONEncoder().encode(PairedLibraryFileRequest(file: file, offset: offset)))
          guard reply.status == 200 else { throw CompanionAPIError(code: "peer_file", message: "The peer did not return a shared file.") }
          let chunk = try JSONDecoder().decode(PairedLibraryFileChunk.self, from: reply.body)
          guard chunk.file == file, chunk.offset == offset else { throw CompanionAPIError(code: "peer_file", message: "Shared file identity changed.") }
          try await files.receive(chunk); chunks += 1
        }
      }
      cursor = page.hasMore ? page.cursor : ""
      try await database.savePairedLibraryFileCursor(cursor, peer: member.deviceID)
      if !page.hasMore { break }
    }
    try await database.materializePendingPeerRecords()
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
      status.state = error is URLError || (error as? CompanionAPIError)?.code == "peer_unavailable" ? .offline : .failing
      status.error = status.state == .offline ? nil : error.localizedDescription
    }
  }

  private func failed(_ member: LibraryMember, _ response: CompanionHTTPResponse) {
    if response.status == 409, let mismatch = try? JSONDecoder().decode(LibraryPeerUpdateRequired.self, from: response.body),
       mismatch.code == "update_required" {
      nextPresence[member.deviceID] = Date().addingTimeInterval(configuration.presenceInterval)
      update(member) { $0.state = .updateRequired; $0.version = mismatch.version; $0.error = mismatch.message; $0.lastContact = Date() }
      return
    }
    let error = (try? JSONDecoder().decode(CompanionAPIError.self, from: response.body))
      ?? CompanionAPIError(code: "peer_sync", message: "The peer refused synchronization (HTTP \(response.status)).")
    offline(member, error)
  }

  /// Tries each advertised endpoint in order. The signature covers the exact
  /// target sent to that endpoint (minus any `/wovenmatter` prefix).
  private func send(_ member: LibraryMember, path: String, body: Data) async throws -> CompanionHTTPResponse {
    var lastError: (any Error) = CompanionAPIError(code: "peer_unavailable", message: "\(member.name) has no address yet.")
    for endpoint in member.endpoints {
      var base = endpoint.path
      if !base.hasSuffix("/") { base += "/" }
      let target = base + path
      do {
        var headers = try directory.identity.signer.headers(method: "POST", target: target, body: body)
        headers["Content-Type"] = "application/json"
        headers["X-Woven-Protocol"] = String(CompanionProtocol.version)
        headers["Host"] = endpoint.host ?? "localhost"
        return try await transport.send(endpoint, .init(method: "POST", target: target, headers: headers, body: body))
      } catch { lastError = error }
    }
    throw lastError
  }

  // MARK: Server

  /// Serves `/v1/peers/sync`, `/v1/peers/notify`, `/v1/peers/files` and
  /// `/v1/peers/file` to signed Mac and Linux members. Returns nil for any
  /// other path or an unsigned request, so older handlers can still answer.
  public func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse? {
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
    do {
      switch path {
      case "/v1/peers/notify":
        guard request.body.count <= 1_024 else { return .error("too_large", "Notice too large.", status: 413) }
        let notice = try JSONDecoder().decode(LibraryPeerNotice.self, from: request.body)
        guard notice.deviceID == member.deviceID else { return .error("wrong_peer", "This notice names another device.", status: 403) }
        online(resolved, synchronized: false)
        let pulled = try await database.pairedLibraryCursors(member.deviceID).pulled
        if notice.cursor > pulled { scheduleSync(member.deviceID, reason: "notice") }
        return try .json(["accepted": true])
      case "/v1/peers/sync":
        guard request.body.count <= 48 * 1_024 * 1_024 else { return .error("too_large", "Page too large.", status: 413) }
        let exchange = try JSONDecoder().decode(LibraryPeerExchange.self, from: request.body)
        guard exchange.deviceID == member.deviceID, exchange.after >= 0 else {
          return .error("wrong_peer", "This exchange names another device.", status: 403)
        }
        let schema = try await database.pairedLibrarySchema()
        guard exchange.page.schema == schema else {
          update(resolved) { $0.state = .updateRequired; $0.version = exchange.version; $0.lastContact = Date()
            $0.error = "\(resolved.name) runs Woven Matter \(exchange.version); this device runs \(self.configuration.version). Update everything to synchronize." }
          return try .json(LibraryPeerUpdateRequired(code: "update_required",
            message: "Update Woven Matter on every device: this device runs \(configuration.version), \(resolved.name) runs \(exchange.version).",
            version: configuration.version, schema: schema), status: 409)
        }
        try await database.receivePairedLibrary(exchange.page, from: member.deviceID)
        // A removal learned in this page ends access before anything returns.
        await directory.invalidate()
        if !exchange.page.entries.isEmpty { await meetNewPeers() }
        guard await directory.member(member.deviceID) != nil else { return .error("unauthorized", "This device was removed.", status: 401) }
        let reply = LibraryPeerExchange(deviceID: directory.identity.deviceID, after: exchange.page.cursor,
          page: try await database.pairedLibraryPage(after: exchange.after), version: configuration.version)
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
    } catch let error as CompanionAPIError {
      return .error(error.code, error.message, status: 409)
    } catch {
      return .error("peer_sync", "Synchronization paused; all local writing is retained. " + error.localizedDescription, status: 409)
    }
  }
}
