import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The headless library host (`wovenmatter-library`). It owns one library
/// database and serves:
/// - on the loopback port, the network routes a machine publishes with
///   Tailscale Serve under `/wovenmatter`: health, identity, peer sync among
///   every Mac and Linux member, and the mobile library API for phones, all
///   authenticated by signed member requests;
/// - on its Unix socket, the local API for this machine's Node server:
///   health, caller registration, the library-backed Woven MCP tools, the
///   member list, local session-history publishing and bot conversations.
/// See docs/architecture/WOVEN_EVERYWHERE.md, "Library host".
public final class LibraryHost: @unchecked Sendable {
  public static let version = "1"
  /// Groups whose tools run entirely against the library database. Note
  /// artifacts (spreadsheet and HTML notes) are part of notes. Rendering an
  /// HTML reply needs the caller's active run, which the Node server owns until
  /// Linux session history is written into this library, so it stays there.
  public static let servedGroups: Set<WorkspaceToolGroup> = [.notes, .history, .calendar, .library]
  public static let maximumRequestBytes = WovenMatterToolRequest.maximumHTMLRequestBytes
  /// Mobile library routes (today's `CompanionWorkspaceAPI`), mounted under
  /// these prefixes so a phone can synchronize with this machine.
  public static let mobilePrefixes = [
    "/v1/hello", "/v1/snapshot", "/v1/changes", "/v1/mutations", "/v1/commands", "/v1/command-receipts/", "/v1/federation/",
    "/v1/calendar", "/v1/dictations", "/v1/notes/", "/v1/assets/", "/v1/sessions/", "/v1/devices", "/v1/providers",
    "/v1/pending", "/v1/workspace-read", "/mcp"
  ]

  public let layout: LibraryHostLayout
  public let store: DashboardStore
  public let database: WorkspaceDatabase
  public let identity: MemberIdentity
  public let members: MemberDirectory
  public let sync: LibraryPeerSync
  private let token: LibraryHostToken
  private let executor: WorkspaceToolExecutor
  private let startedAt = Date()
  private let lock = NSLock()
  private var mounts: [(prefix: String, handler: CompanionHTTPResponseHandler)] = []
  private var servers: [CompanionSocketHTTPServer] = []
  private var mobile: CompanionWorkspaceAPI?

  /// `name` and `endpoints` are this machine's own advertised entry (the Mac
  /// that adds it signs the authoritative one); `transport` is for tests.
  public init(layout: LibraryHostLayout, tokenFile: URL? = nil, name: String? = nil, endpoints: [URL] = [],
              transport: LibraryPeerTransport = .urlSession(), presenceInterval: TimeInterval = 60) async throws {
    try layout.prepare()
    LinuxSecretStore.directory = layout.secrets
    self.layout = layout
    token = try LibraryHostToken.load(tokenFile ?? layout.defaultTokenFile)
    store = try await DashboardStore(supportDirectory: layout.library)
    try await store.prepareLocalWorkspace()
    database = store.database
    executor = WorkspaceToolExecutor(database: database)
    let library = try await database.companionLibraryIdentity()
    identity = try MemberIdentity.loadOrCreate(file: layout.memberKeyFile, deviceID: library.hostDeviceID, kind: .linux)
    members = MemberDirectory(database: database, identity: identity)
    try await members.ensureSelf(name: name ?? ProcessInfo.processInfo.hostName, endpoints: endpoints)
    var configuration = LibraryPeerSync.Configuration(version: "wovenmatter-library " + Self.version)
    configuration.presenceInterval = presenceInterval
    sync = LibraryPeerSync(directory: members, transport: transport, configuration: configuration)
    let sync = sync
    for prefix in ["/v1/peers/sync", "/v1/peers/notify", "/v1/peers/file"] {
      mount(prefix: prefix) { await sync.handle($0) ?? .error("unauthorized", "Peer routes need a signed member request.", status: 401) }
    }
    // Bearer grants are never issued here; the store only backs the API.
    let authentication = try CompanionAuthentication(fileURL: layout.library.appending(path: "companion-devices.json"))
    let api = await MainActor.run { [database, members, executor] in
      CompanionWorkspaceAPI(database: database, authentication: authentication, commands: LibraryHostCommands(executor: executor),
                            isActive: { true }, members: members)
    }
    mobile = api
    for prefix in Self.mobilePrefixes {
      mount(prefix: prefix) { request in
        // Phones authenticate only by member signature here.
        guard MemberRequestVerifier.isSigned(request.headers) else {
          return .error("unauthorized", "Sign this request with a member device key.", status: 401)
        }
        return await api.handle(request)
      }
    }
  }

  /// Starts peer synchronization: one catch-up with every peer, then
  /// change-driven announcements and a slow presence check.
  public func startSync() async { await sync.start() }

  /// Routes another handler under a loopback path prefix, such as `/v1/peers/`
  /// for peer sync or `/v1/workspace/` for the mobile API. Requests reach it
  /// with the `/wovenmatter` Serve prefix already removed.
  public func mount(prefix: String, _ handler: @escaping CompanionHTTPResponseHandler) {
    lock.withLock { mounts.append((prefix, handler)); mounts.sort { $0.prefix.count > $1.prefix.count } }
  }

  @discardableResult
  public func listen(port: UInt16, socket: URL) throws -> UInt16 {
    let network = CompanionSocketHTTPServer { [weak self] request in
      await self?.handleNetwork(request) ?? .error("unavailable", "The library host stopped.", status: 503)
    }
    let local = CompanionSocketHTTPServer { [weak self] request in
      await self?.handleLocal(request) ?? .error("unavailable", "The library host stopped.", status: 503)
    }
    let bound = try network.start(.loopback(port: port))
    do { try local.start(.unix(path: socket.path)) } catch { network.stop(); throw error }
    lock.withLock { servers = [network, local] }
    return bound
  }

  public func stop() {
    let current = lock.withLock { defer { servers = [] }; return servers }
    for server in current { server.stop() }
    let sync = sync
    Task { await sync.stop() }
  }

  // MARK: Loopback routes

  func handleNetwork(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard var path = URLComponents(string: "http://localhost" + request.target)?.path else {
      return .error("invalid_request", "Invalid request path.", status: 400)
    }
    if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
    if path == "/v1/health" { return await health(request) }
    if path == "/v1/identity" { return identityResponse(request) }
    let handler = lock.withLock { mounts.first { path.hasPrefix($0.prefix) }?.handler }
    guard let handler else { return .error("not_found", "This library route is not served here.", status: 404) }
    return await handler(request)
  }

  // MARK: Local (Unix socket) routes

  func handleLocal(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard token.accepts(request.bearer) else {
      return .init(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"woven-library\""],
                   body: Data("{\"code\":\"unauthorized\",\"message\":\"A valid library API token is required.\"}".utf8))
    }
    guard let path = URLComponents(string: "http://localhost" + request.target)?.path else {
      return .error("invalid_request", "Invalid request path.", status: 400)
    }
    do {
      switch path {
      case "/v1/health": return await health(request)
      case "/v1/identity": return identityResponse(request)
      case "/v1/callers": return try await registerCaller(request)
      case "/v1/mcp": return try await mcp(request)
      case "/v1/members":
        guard request.method == "GET" else { return .error("method_not_allowed", "Use GET.", status: 405) }
        return try .json(try await members.list())
      case "/v1/members/adopt":
        guard request.method == "POST", request.body.count <= 1_048_576 else { return .error("invalid_request", "POST an adoption of at most 1 MiB.", status: 400) }
        let list = try await members.adopt(JSONDecoder().decode(LibraryMemberAdoption.self, from: request.body))
        await sync.scheduleAll()
        return try .json(list)
      case "/v1/members/self":
        guard request.method == "POST", request.body.count <= 8_192 else { return .error("invalid_request", "POST at most 8 KiB.", status: 400) }
        struct Update: Decodable { var name: String?; var endpoints: [URL] }
        let update = try JSONDecoder().decode(Update.self, from: request.body)
        guard update.endpoints.count <= 8, update.endpoints.allSatisfy({ CompanionPairingPayload.isValidEndpoint($0) }) else {
          return .error("invalid_request", "Endpoints must be HTTPS tailnet addresses.", status: 400)
        }
        try await members.ensureSelf(name: update.name ?? ProcessInfo.processInfo.hostName, endpoints: update.endpoints)
        return try .json(try await members.list())
      case "/v1/sync/status":
        return try .json(await sync.status())
      default:
        if path.hasPrefix("/v1/publisher/") {
          return try await CompanionWorkspacePublisherAPI.handleLocal(request, path: path, database: database)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "v1", parts[1] == "bots", parts[3] == "entries" {
          guard request.method == "POST" else { return .error("method_not_allowed", "Use POST.", status: 405) }
          guard request.body.count <= 8 * 1_024 * 1_024 else { return .error("too_large", "The conversation batch is too large.", status: 413) }
          let batch = try JSONDecoder().decode(BotEntriesBatch.self, from: request.body)
          return try .json(try await database.writeBotEntries(machineID: identity.deviceID, botID: parts[2], batch: batch))
        }
        return .error("not_found", "Unknown library API route.", status: 404)
      }
    } catch let error as CompanionAPIError {
      return .error(error.code, error.message, status: error.code == "too_large" ? 413 : error.code == "wrong_owner" ? 403 : 400)
    } catch {
      return .error("invalid_request", error.localizedDescription, status: 400)
    }
  }

  public struct Identity: Codable, Sendable, Equatable {
    public let deviceID: String
    public let kind: MemberKind
    public let name: String
    /// Raw 32-byte Ed25519 public key, base64.
    public let publicKey: Data
  }
  public func identityValue() -> Identity {
    .init(deviceID: identity.deviceID, kind: identity.kind, name: ProcessInfo.processInfo.hostName, publicKey: identity.publicKey)
  }
  /// Public by design: the adding Mac reads it to sign this machine's entry.
  private func identityResponse(_ request: CompanionHTTPRequest) -> CompanionHTTPResponse {
    guard request.method == "GET" else { return .error("method_not_allowed", "Use GET.", status: 405) }
    return (try? .json(identityValue())) ?? .error("unavailable", "Identity unavailable.", status: 503)
  }

  private func health(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard request.method == "GET" else { return .error("method_not_allowed", "Use GET.", status: 405) }
    struct Health: Encodable {
      let status: String; let service: String; let version: String
      let deviceID: String; let uptimeSeconds: Int
    }
    do {
      _ = try await database.toolSettings()
      return try .json(Health(status: "ok", service: "wovenmatter-library", version: Self.version,
        deviceID: identity.deviceID, uptimeSeconds: Int(Date().timeIntervalSince(startedAt))))
    } catch {
      return .error("unavailable", "The library database is unavailable: \(error.localizedDescription)", status: 503)
    }
  }

  /// `POST /v1/callers` registers one of the Node server's conversations as a
  /// local session, so Woven tools attribute notes, receipts and versions to it.
  public struct CallerRegistration: Codable, Sendable {
    public var conversationID: String
    public var title: String?
    public var runtimeKind: String?
    public var workingDirectory: String?
    public var enabledGroups: [String]?
  }

  private func registerCaller(_ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
    guard request.method == "POST" else { return .error("method_not_allowed", "Use POST.", status: 405) }
    guard request.body.count <= 16_384 else { return .error("too_large", "The caller registration is too large.", status: 413) }
    let registration = try JSONDecoder().decode(CallerRegistration.self, from: request.body)
    let groups = try Self.groups(registration.enabledGroups ?? [])
    let id = try await ensureCaller(registration.conversationID, groups: groups, title: registration.title,
      runtimeKind: registration.runtimeKind, workingDirectory: registration.workingDirectory)
    return try .json(["conversationID": id, "enabledGroups": groups.map(\.rawValue).sorted().joined(separator: ",")])
  }

  /// Creates the caller on first use, then applies the Node server's current
  /// tool selection, limited to the groups this host serves.
  @discardableResult
  public func ensureCaller(_ rawID: String, groups: Set<WorkspaceToolGroup>, title: String? = nil,
                           runtimeKind: String? = nil, workingDirectory: String? = nil) async throws -> String {
    guard let uuid = UUID(uuidString: rawID) else {
      throw CompanionAPIError(code: "invalid_request", message: "Callers are identified by conversation UUIDs.")
    }
    let id = uuid.uuidString.lowercased()
    let exists = try await database.hasActiveConversation(id)
    if !exists {
      let kind = runtimeKind.flatMap(AgentRuntimeKind.init(rawValue:)) ?? .defaultAgent
      let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
      let location = WorkspaceFolderLocation(workspaceID: try await store.executionWorkspaceID(), rootPath: directory, managed: false)
      let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await store.createLocalACPSession(runtimeKind: kind,
        title: String((cleanTitle?.isEmpty == false ? cleanTitle! : "Linux session").prefix(512)),
        requestedConversationID: uuid,
        executionRoot: .init(folderID: nil, location: location, defaultPath: directory))
    }
    let current = try await database.sessionTools(id)
    let selected = groups.intersection(Self.servedGroups)
    if current.enabled != selected {
      try await database.setSessionTools(.init(enabled: selected, executorProfiles: current.executorProfiles),
        sessionID: id, confirmedPausingTimers: true)
    }
    return id
  }

  /// `POST /v1/mcp`: stateless MCP JSON-RPC, the same messages the Node server
  /// sends a Mac's `/mcp/workspace`. The caller and its tool selection come
  /// from `X-Woven-Conversation-ID` and `X-Woven-Enabled-Groups`.
  private func mcp(_ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
    guard request.method == "POST" else {
      return .error("method_not_allowed", "Woven MCP accepts stateless JSON-RPC POST requests.", status: 405)
    }
    if let version = request.headers["mcp-protocol-version"], !WovenMCPServer.supportedProtocolVersions.contains(version) {
      return .error("protocol_version", "Unsupported MCP protocol version.", status: 400)
    }
    guard let rawCaller = request.headers["x-woven-conversation-id"],
          let rawGroups = request.headers["x-woven-enabled-groups"], rawGroups.utf8.count <= 512 else {
      return .error("invalid_request", "MCP requires a conversation binding and its current tool selection.", status: 400)
    }
    let groups = try Self.groups(rawGroups.split(separator: ",").map(String.init))
    let message: GatewayJSONValue
    do { message = try JSONDecoder().decode(GatewayJSONValue.self, from: request.body) }
    catch { return try .json(WovenMCPServer.error(code: -32700, message: "The MCP request could not be decoded.")) }
    guard request.body.count <= WovenMCPServer.maximumRequestBytes(for: message) else {
      return .error("too_large", "The MCP request exceeds its size limit.", status: 413)
    }
    let callerID = try await ensureCaller(rawCaller, groups: groups)
    let served = groups.intersection(Self.servedGroups)
    let allowed = Set(WovenMCPCatalog.tools.filter { tool in
      tool.name == "woven_context" || tool.group.map(served.contains) == true
    }.map(\.name))
    let contextID = request.headers["x-woven-context-id"]
      ?? message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["wovenContextID"]?.stringValue
    let executor = executor
    let result = await WovenMCPServer.handle(message, contextID: contextID, allowedTools: allowed) { call in
      await executor.execute(call, callerID: callerID, handlers: WorkspaceToolHandlers()).bounded()
    }
    guard let result else { return .init(status: 202, body: Data()) }
    return try .json(result)
  }

  static func groups(_ names: [String]) throws -> Set<WorkspaceToolGroup> {
    let values = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let groups = values.compactMap(WorkspaceToolGroup.init(rawValue:))
    guard groups.count == values.count else {
      throw CompanionAPIError(code: "invalid_request", message: "An unknown tool group was selected.")
    }
    return Set(groups)
  }
}

/// The mobile API's command surface on a headless host: library tools run
/// against this database; sessions are started on a Mac or this machine's
/// own workspace, never from the phone through the library host.
@MainActor
final class LibraryHostCommands: CompanionCommandServing {
  private let executor: WorkspaceToolExecutor
  init(executor: WorkspaceToolExecutor) { self.executor = executor }
  private var unsupported: CompanionAPIError {
    .init(code: "unsupported", message: "This Linux machine's library does not run sessions for other devices. Use its workspace.")
  }
  func executeTool(_ request: CompanionToolRequest, deviceID: String) async throws -> WovenMatterToolResponse {
    await executor.execute(request.request, callerID: request.conversationID, handlers: WorkspaceToolHandlers())
  }
  func providers() -> [CompanionProvider] { [] }
  func pendingInteractions() async -> [CompanionPendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { throw unsupported }
  func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript { throw unsupported }
  func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt? { nil }
  func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt { throw unsupported }
}
