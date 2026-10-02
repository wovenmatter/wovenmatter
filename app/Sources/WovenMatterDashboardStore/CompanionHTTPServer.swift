import Foundation
import Network
import WovenMatterCore

public struct CompanionHTTPRequest: Sendable {
  public let method: String
  public let target: String
  public let headers: [String: String]
  public let body: Data
  public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
    self.method = method; self.target = target; self.headers = headers; self.body = body
  }
  public var bearer: String? {
    guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
    return String(value.dropFirst(7))
  }
}

public struct CompanionHTTPResponse: Sendable {
  public let status: Int
  public let contentType: String
  public let body: Data
  public init(status: Int = 200, contentType: String = "application/json", body: Data) {
    self.status = status; self.contentType = contentType; self.body = body
  }
  public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
    Self(status: status, body: try JSONEncoder().encode(value))
  }
  public static func error(_ code: String, _ message: String, status: Int) -> Self {
    (try? .json(CompanionAPIError(code: code, message: message), status: status))
      ?? Self(status: 500, body: Data())
  }
}

/// A deliberately narrow HTTP/1.1 reader for Tailscale's loopback reverse proxy.
/// No upgrades, chunking, request pipelining, cookies or browser origins are accepted.
public struct CompanionHTTPParser: Sendable {
  public static let maximumHeaderBytes = 32 * 1_024
  public static let maximumBodyBytes = 16 * 1_024 * 1_024
  private var buffer = Data()
  public init() {}
  public mutating func append(_ bytes: Data) throws -> CompanionHTTPRequest? {
    guard bytes.count <= Self.maximumBodyBytes + Self.maximumHeaderBytes - buffer.count else {
      throw CompanionAPIError(code: "too_large", message: "Request exceeds the size limit.")
    }
    buffer.append(bytes)
    guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      guard buffer.count <= Self.maximumHeaderBytes else { throw malformed }
      return nil
    }
    guard separator.lowerBound <= Self.maximumHeaderBytes,
          let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { throw malformed }
    let lines = header.components(separatedBy: "\r\n")
    guard let first = lines.first, lines.count <= 101 else { throw malformed }
    let parts = first.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, ["GET", "POST"].contains(parts[0]),
          parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
          parts[2] == "HTTP/1.1", parts[1].utf8.count <= 8_192 else { throw malformed }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let split = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw malformed }
      let name = String(line[..<split]).lowercased()
      let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }),
            headers[name] == nil else { throw malformed }
      headers[name] = value
    }
    guard headers["host"] != nil, headers["transfer-encoding"] == nil,
          headers["upgrade"] == nil, headers["expect"] == nil,
          headers["origin"] == nil, headers["cookie"] == nil else { throw malformed }
    let length: Int
    if let raw = headers["content-length"] {
      guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let parsed = Int(raw), parsed <= Self.maximumBodyBytes else { throw malformed }
      length = parsed
    } else { length = 0 }
    guard parts[0] != "GET" || length == 0,
          parts[0] != "POST" || headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { throw malformed }
    let count = buffer.count - separator.upperBound
    guard count <= length else { throw malformed }
    guard count == length else { return nil }
    return CompanionHTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers,
                                body: Data(buffer[separator.upperBound...]))
  }
  private var malformed: CompanionAPIError { CompanionAPIError(code: "invalid_request", message: "Invalid companion request.") }
}

/// Each connection has its own bounded reader. Request tasks do not own Mac runs,
/// and closing a connection intentionally does not cancel an accepted command.
public final class CompanionHTTPServer: @unchecked Sendable {
  public typealias Handler = @Sendable (CompanionHTTPRequest) async -> CompanionHTTPResponse
  private let queue = DispatchQueue(label: "com.wovenmatter.companion.http")
  private let handler: Handler
  private var listener: NWListener?
  private var clients: [UUID: CompanionHTTPConnection] = [:]
  private var startContinuation: CheckedContinuation<UInt16, any Error>?
  public init(handler: @escaping Handler) { self.handler = handler }

  public func start(port: UInt16 = 0) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard listener == nil else { continuation.resume(throwing: CompanionAPIError(code: "already_running", message: "Companion listener is already running.")); return }
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
          let next = try NWListener(using: parameters)
          startContinuation = continuation
          listener = next
          next.stateUpdateHandler = { [weak self] state in
            guard let self, self.listener === next else { return }
            switch state {
            case .ready:
              if let port = self.listener?.port?.rawValue { self.startContinuation?.resume(returning: port); self.startContinuation = nil }
            case .failed(let error): self.failStart(error)
            case .cancelled: self.failStart(CancellationError())
            default: break
            }
          }
          next.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
          next.start(queue: queue)
          queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.listener === next, self.startContinuation != nil else { return }
            self.failStart(CompanionAPIError(code: "listener_timeout", message: "The companion listener could not start."))
          }
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  public func stop() {
    queue.async { [self] in
      listener?.cancel(); listener = nil
      failStart(CancellationError())
      for client in clients.values { client.cancel() }
      clients.removeAll()
    }
  }

  private func failStart(_ error: any Error) {
    startContinuation?.resume(throwing: error); startContinuation = nil
  }
  private func accept(_ connection: NWConnection) {
    guard clients.count < 32 else { connection.cancel(); return }
    let id = UUID()
    let client = CompanionHTTPConnection(connection: connection, queue: queue, handler: handler) { [weak self] in
      self?.clients.removeValue(forKey: id)
    }
    clients[id] = client
    client.start()
  }
}

private final class CompanionHTTPConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let handler: CompanionHTTPServer.Handler
  private let onClose: @Sendable () -> Void
  private var parser = CompanionHTTPParser()
  private var closed = false
  private var processing = false
  init(connection: NWConnection, queue: DispatchQueue, handler: @escaping CompanionHTTPServer.Handler, onClose: @escaping @Sendable () -> Void) {
    self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
  }
  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state { case .failed, .cancelled: self?.cancel(); default: break }
    }
    connection.start(queue: queue)
    receive()
    queue.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let self, !self.processing else { return }; self.cancel()
    }
    queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.cancel() }
  }
  func cancel() {
    guard !closed else { return }; closed = true
    connection.cancel(); onClose()
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
      guard let self, !self.closed else { return }
      do {
        if let request = try self.parser.append(data ?? Data()) {
          self.processing = true
          Task { [self] in
            let response = await handler(request)
            queue.async { [self] in send(response) }
          }
        } else if complete || error != nil { self.cancel() }
        else { self.receive() }
      } catch {
        self.send(.error("invalid_request", "Invalid or oversized companion request.", status: 400))
      }
    }
  }
  private func send(_ response: CompanionHTTPResponse) {
    guard !closed else { return }
    let reason = response.status == 200 ? "OK" : "Request Error"
    var wire = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
    wire.append(response.body)
    connection.send(content: wire, completion: .contentProcessed { [weak self] _ in self?.cancel() })
  }
}
