import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How a runtime reaches the Woven MCP: a stdio MCP server it starts, which is
/// a bridge to this server's tool socket, and Woven's instructions for its
/// own instruction mechanism.
public struct ToolAccess: Sendable, Hashable {
  public var command: String
  public var arguments: [String]
  public var environment: [String: String]
  public var instructions: String

  /// As ACP's `mcpServers` lists a stdio server.
  var acpServer: JSONValue {
    .object(["name": .string("woven"), "command": .string(command), "args": .array(arguments.map(JSONValue.string)),
             "env": .array(environment.sorted { $0.key < $1.key }.map {
               .object(["name": .string($0.key), "value": .string($0.value)])
             })])
  }
}

/// Who a connection to the tool socket speaks for. A bridge says its key
/// first; the key was given only to that runtime, in memory, by this server.
enum ToolGrant: Sendable, Hashable {
  /// One session.
  case session(String)
  /// A runtime that serves several sessions through one bridge (OpenCode),
  /// naming the native session in each call.
  case runtime(RuntimeKind)
}

/// The keys of this server's tool socket.
final class ToolKeys: Sendable {
  let socketPath: String
  private let grants = Mutex<[String: ToolGrant]>([:])

  init(socketPath: String) { self.socketPath = socketPath }

  /// The access a runtime is given for `grant`. The bridge runs with Node,
  /// which every machine that runs agents has.
  func access(_ grant: ToolGrant) -> ToolAccess? {
    let node = Resources.node ?? "node"
    let key = grants.withLock { grants -> String in
      if let existing = grants.first(where: { $0.value == grant })?.key { return existing }
      let key = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
      grants[key] = grant
      return key
    }
    return ToolAccess(command: node, arguments: [Resources.harnesses.appendingPathComponent("woven-mcp.mjs").path, socketPath],
                      environment: ["WOVEN_MCP_KEY": key], instructions: WovenInstructions.text)
  }

  func grant(for key: String) -> ToolGrant? { grants.withLock { $0[key] } }
}

/// The tool socket: a Unix socket only this machine's user can open, speaking
/// MCP as newline-delimited JSON-RPC after the bridge's key.
final class MCPEndpoint: Sendable {
  private let keys: ToolKeys
  private let tools: WovenTools
  private let listener = Mutex<Int32>(-1)

  init(keys: ToolKeys, tools: WovenTools) {
    self.keys = keys
    self.tools = tools
  }

  /// A socket path short enough for `sockaddr_un`, in `folder` when it fits.
  static func socketPath(in folder: URL) -> String {
    let path = folder.appendingPathComponent("tools.sock").path
    if path.utf8.count < 100 { return path }
    let digest = SHA256.hash(data: Data(folder.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return "/tmp/woven-tools-\(getuid())-\(digest).sock"
  }

  func start() throws {
    let path = keys.socketPath
    unlink(path)
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { throw ToolFailure("The tool socket could not be made.") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
    }
    // Owner-only before it listens, so nobody else can ever connect.
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
      close(fd)
      throw ToolFailure("The tool socket could not listen at \(path).")
    }
    listener.withLock { $0 = fd }
    Thread.detachNewThread { [self] in
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        Thread.detachNewThread { MCPConnection(fd: client, keys: self.keys, tools: self.tools).run() }
      }
    }
  }

  func stop() {
    let fd = listener.withLock { fd -> Int32 in defer { fd = -1 }; return fd }
    guard fd >= 0 else { return }
    shutdown(fd, Int32(SHUT_RDWR))
    close(fd)
    unlink(keys.socketPath)
  }
}

/// One bridge's connection: its key, then MCP requests until it closes.
private final class MCPConnection: @unchecked Sendable {
  private let fd: Int32
  private let keys: ToolKeys
  private let tools: WovenTools
  /// Whether the socket is closed; writes hold it, so none goes to a reused descriptor.
  private let closed = Mutex(false)
  private var grant: ToolGrant?

  init(fd: Int32, keys: ToolKeys, tools: WovenTools) {
    self.fd = fd
    self.keys = keys
    self.tools = tools
  }

  func run() {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    reading: while true {
      let count = read(fd, &chunk, chunk.count)
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      buffer.append(contentsOf: chunk[0..<count])
      while let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[buffer.startIndex..<end])
        buffer.removeSubrange(buffer.startIndex...end)
        guard let message = try? Wire.decoder.decode(JSONValue.self, from: line) else { continue }
        if grant == nil {
          guard let key = message["key"]?.string, let found = keys.grant(for: key) else { break reading }
          grant = found
          continue
        }
        let grant = grant!
        Task { await self.handle(message, grant: grant) }
      }
      if buffer.count > 64 << 20 { break }
    }
    closed.withLock { closed in
      closed = true
      close(fd)
    }
  }

  private func handle(_ message: JSONValue, grant: ToolGrant) async {
    guard let method = message["method"]?.string else { return }
    let id = message["id"]
    let params = message["params"] ?? .object([:])
    let result: JSONValue
    switch method {
    case "initialize":
      result = .object([
        "protocolVersion": params["protocolVersion"] ?? .string("2025-06-18"),
        "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
        "serverInfo": .object(["name": .string("woven"), "title": .string("Woven Matter"), "version": .string("1")]),
      ])
    case "ping":
      result = .object([:])
    case "tools/list":
      // A session is shown only the groups it may use.
      let enabled: Set<ToolGroup>? = if case .session(let id) = grant { await tools.enabledGroups(sessionID: id) } else { nil }
      result = .object(["tools": .array(tools.listing(enabled: enabled))])
    case "tools/call":
      let outcome: ToolResult
      if let caller = await caller(grant, params) {
        outcome = await tools.call(params["name"]?.string ?? "", arguments: params["arguments"] ?? .object([:]), caller: caller)
      } else {
        outcome = .error("This session is not one Woven Matter runs, so it cannot use Woven tools.")
      }
      result = (try? JSONValue(encoding: outcome)) ?? .object([:])
    default:
      guard let id, id != .null else { return }
      send(.object(["jsonrpc": .string("2.0"), "id": id,
                    "error": .object(["code": .integer(-32601), "message": .string("Woven has no method \(method).")])]))
      return
    }
    guard let id, id != .null else { return }
    send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
  }

  private func caller(_ grant: ToolGrant, _ params: JSONValue) async -> ToolCaller? {
    switch grant {
    case .session(let id):
      return ToolCaller(machineID: tools.machineID, sessionID: id)
    case .runtime(let kind):
      // OpenCode names its native session in each call.
      guard let native = params["_meta"]?["ai.opencode/sessionID"]?.string,
            let id = try? await tools.library.session(runtime: kind, nativeHandle: native) else { return nil }
      return ToolCaller(machineID: tools.machineID, sessionID: id)
    }
  }

  private func send(_ value: JSONValue) {
    guard var data = try? Wire.encoder.encode(value) else { return }
    data.append(10)
    closed.withLock { closed in
      guard !closed else { return }
      data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
          if written < 0 && errno == EINTR { continue }
          if written <= 0 { return }
          offset += written
        }
      }
    }
  }
}
