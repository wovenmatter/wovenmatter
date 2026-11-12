import Foundation
import WovenMatterShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a member's stream is: `GET <endpoint>/v1/stream?protocol=1`, upgraded.
public enum StreamEndpoint {
  /// The WebSocket URL under a member's endpoint (a Mac's
  /// `https://<mac>.<tailnet>.ts.net:<port>/wovenmatter`, a Linux host's
  /// `…/wovenmatter-execution/<id>/`). Only private tailnet HTTPS endpoints.
  public static func url(for endpoint: URL) throws -> URL {
    guard endpoint.scheme == "https", endpoint.host?.lowercased().hasSuffix(".ts.net") == true,
          endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
          !endpoint.pathComponents.contains("..") else { throw StreamConnectionError.insecureEndpoint }
    let base = endpoint.absoluteString.hasSuffix("/") ? endpoint : endpoint.appendingPathComponent("")
    guard let url = URL(string: StreamProtocol.path + "?" + StreamProtocol.query, relativeTo: base)?.absoluteURL,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw StreamConnectionError.insecureEndpoint }
    components.scheme = "wss"
    guard let socket = components.url else { throw StreamConnectionError.insecureEndpoint }
    return socket
  }

  /// The signed target: the path and query exactly as sent.
  public static func target(of url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
    return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
  }

  /// Member signature headers for one upgrade (`GET`, empty body).
  public static func signedHeaders(for url: URL, signer: MemberRequestSigner, audience: String) throws -> [String: String] {
    try signer.headers(method: "GET", target: target(of: url), audience: audience)
  }
}

/// The stream on a member-signed `URLSessionWebSocketTask`.
public final class WebSocketStreamTransport: StreamTransport, @unchecked Sendable {
  /// Upgrade headers for one attempt, asked for afresh every time.
  public typealias Authorize = @Sendable (_ url: URL) async throws -> [String: String]
  private let task: URLSessionWebSocketTask

  init(task: URLSessionWebSocketTask) { self.task = task }

  /// Opens one socket per call. `authorize` signs (or asks the process that
  /// holds the member key to sign) every attempt; `headers` go on every upgrade.
  public static func connector(endpoint: URL, headers: [String: String] = [:], session: URLSession? = nil,
                               authorize: @escaping Authorize) throws -> StreamConnection.Connect {
    let url = try StreamEndpoint.url(for: endpoint)
    let session = session ?? Self.session
    return {
      let request = try await Self.request(url: url, headers: headers, authorize: authorize)
      let task = session.webSocketTask(with: request)
      task.maximumMessageSize = StreamProtocol.maximumFrameBytes
      task.resume()
      return WebSocketStreamTransport(task: task)
    }
  }

  /// A connector that signs with this device's own member key.
  public static func connector(endpoint: URL, signer: MemberRequestSigner, audience: String, headers: [String: String] = [:],
                               session: URLSession? = nil) throws -> StreamConnection.Connect {
    try connector(endpoint: endpoint, headers: headers, session: session) { url in
      try StreamEndpoint.signedHeaders(for: url, signer: signer, audience: audience)
    }
  }

  /// The upgrade request for one attempt.
  public static func request(url: URL, headers: [String: String], authorize: Authorize) async throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 30)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    for (name, value) in try await authorize(url) { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  /// The client's decode path for one WebSocket message.
  public static func decode(_ message: URLSessionWebSocketTask.Message) throws -> StreamFrame {
    switch message {
    case .string(let text): try StreamProtocol.decode(Data(text.utf8))
    case .data(let data): try StreamProtocol.decode(data)
    @unknown default: .unknown("")
    }
  }

  public func receive() async throws -> StreamFrame {
    let message: URLSessionWebSocketTask.Message
    do { message = try await task.receive() } catch { throw failure(error) }
    do { return try Self.decode(message) }
    catch {
      await close(.protocolViolation)
      throw StreamTransportClosed(code: StreamProtocol.CloseCode.protocolViolation.rawValue, reason: "Unreadable frame.")
    }
  }

  public func send(_ frame: StreamFrame) async throws {
    let text = String(decoding: try StreamProtocol.encode(frame), as: UTF8.self)
    do { try await task.send(.string(text)) } catch { throw failure(error) }
  }

  public func ping() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      task.sendPing { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  public func close(_ code: StreamProtocol.CloseCode) async {
    task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code.rawValue) ?? .normalClosure, reason: nil)
  }

  /// A refused upgrade (its `X-Woven-Error`, `Date` and status), or the close code the server sent.
  private func failure(_ error: any Error) -> any Error {
    if let response = task.response as? HTTPURLResponse, let refusal = StreamConnectionError.refusal(response) { return refusal }
    if task.closeCode != .invalid {
      return StreamTransportClosed(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) })
    }
    return StreamTransportClosed()
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }()
  private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  }
}

/// A byte channel to a Woven server: the Mac window's Unix socket to its own
/// background server, which another component supplies. Unix socket
/// permissions authenticate it; there is no upgrade or signature.
public protocol StreamByteChannel: Sendable {
  /// The next bytes, or nil at the end of the stream.
  func read() async throws -> Data?
  func write(_ data: Data) async throws
  func close() async
}

/// The stream over a byte channel: each frame a 4-byte big-endian length and its JSON.
public actor LengthPrefixedStreamTransport: StreamTransport {
  private let channel: any StreamByteChannel
  private var buffer = Data()
  private var ready: [StreamFrame] = []

  public init(channel: any StreamByteChannel) { self.channel = channel }

  public func receive() async throws -> StreamFrame {
    while ready.isEmpty {
      guard let bytes = try await channel.read() else { throw StreamTransportClosed() }
      buffer.append(bytes)
      do { ready = try StreamProtocol.takeLengthPrefixedFrames(from: &buffer) }
      catch {
        await channel.close()
        throw StreamTransportClosed(code: StreamProtocol.CloseCode.protocolViolation.rawValue, reason: "Unreadable frame.")
      }
    }
    return ready.removeFirst()
  }

  public func send(_ frame: StreamFrame) async throws { try await channel.write(StreamProtocol.lengthPrefixed(frame)) }
  /// Liveness is the socket itself: a closed Unix socket ends `read()`.
  public func ping() async throws {}
  public func close(_ code: StreamProtocol.CloseCode) async { await channel.close() }
}
