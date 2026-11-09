import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The headless library host (`wovenmatter-library`). It owns one library
/// database and serves:
/// - on the loopback port, the network routes a machine publishes with
///   Tailscale Serve under `/wovenmatter`: `GET /v1/health` now, and the peer
///   sync and mobile library routes through `mount(prefix:_:)`;
/// - on its Unix socket, the local API for this machine's Node server:
///   health, caller registration and the library-backed Woven MCP tools.
/// See docs/architecture/WOVEN_EVERYWHERE.md, "Library host".
public final class LibraryHost: @unchecked Sendable {
  public static let version = "1"
  /// Groups whose tools run entirely against the library database. Note
  /// artifacts (spreadsheet and HTML notes) are part of notes. Rendering an
  /// HTML reply needs the caller's active run, which the Node server owns until
  /// Linux session history is written into this library, so it stays there.
  public static let servedGroups: Set<WorkspaceToolGroup> = [.notes, .history, .calendar, .library]
  public static let maximumRequestBytes = WovenMatterToolRequest.maximumHTMLRequestBytes

  public let layout: LibraryHostLayout
  public let store: DashboardStore
  public let database: WorkspaceDatabase
  private let token: LibraryHostToken
  private let executor: WorkspaceToolExecutor
  private let startedAt = Date()
  private let lock = NSLock()
  private var mounts: [(prefix: String, handler: CompanionHTTPResponseHandler)] = []
  private var servers: [CompanionSocketHTTPServer] = []

  public init(layout: LibraryHostLayout, tokenFile: URL? = nil) async throws {
    try layout.prepare()
    LinuxSecretStore.directory = layout.secrets
    self.layout = layout
    token = try LibraryHostToken.load(tokenFile ?? layout.defaultTokenFile)
    store = try await DashboardStore(supportDirectory: layout.library)
    try await store.prepareLocalWorkspace()
    database = store.database
    executor = WorkspaceToolExecutor(database: database)
  }

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
  }

  // MARK: Loopback routes

  func handleNetwork(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard var path = URLComponents(string: "http://localhost" + request.target)?.path else {
      return .error("invalid_request", "Invalid request path.", status: 400)
    }
    if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
    if path == "/v1/health" { return await health(request) }
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
      case "/v1/callers": return try await registerCaller(request)
      case "/v1/mcp": return try await mcp(request)
      default: return .error("not_found", "Unknown library API route.", status: 404)
      }
    } catch let error as CompanionAPIError {
      return .error(error.code, error.message, status: 400)
    } catch {
      return .error("invalid_request", error.localizedDescription, status: 400)
    }
  }

  private func health(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
    guard request.method == "GET" else { return .error("method_not_allowed", "Use GET.", status: 405) }
    struct Health: Encodable {
      let status: String; let service: String; let version: String
      let deviceID: String; let uptimeSeconds: Int
    }
    do {
      let deviceID = try await store.dashboardDeviceID().uuidString.lowercased()
      _ = try await database.toolSettings()
      return try .json(Health(status: "ok", service: "wovenmatter-library", version: Self.version,
        deviceID: deviceID, uptimeSeconds: Int(Date().timeIntervalSince(startedAt))))
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
