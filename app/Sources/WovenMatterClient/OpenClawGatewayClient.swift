import CryptoKit
import Foundation
import WovenMatterCore

public enum GatewayJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: GatewayJSONValue])
  case array([GatewayJSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([String: GatewayJSONValue].self) { self = .object(value) }
    else { self = .array(try container.decode([GatewayJSONValue].self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var objectValue: [String: GatewayJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [GatewayJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(exactly: value)
  }
}

public struct OpenClawGatewayEvent: Equatable, Sendable {
  public let name: String
  public let payload: GatewayJSONValue?
  public let sequence: Int?
}

public enum OpenClawGatewayClientError: LocalizedError, Equatable, Sendable {
  case invalidEndpoint
  case connectionClosed
  case malformedFrame
  case challengeMissing
  case authenticationMissing
  case unavailable(String, retryAfterMilliseconds: Int?)
  case rejected(String)
  case unsupportedCapability(String)
  case requestTimedOut(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "The OpenClaw Gateway endpoint is invalid."
    case .connectionClosed: "The OpenClaw Gateway connection is unavailable."
    case .malformedFrame: "OpenClaw Gateway returned an invalid protocol frame."
    case .challengeMissing: "OpenClaw Gateway did not provide a connection challenge."
    case .authenticationMissing: "OpenClaw Gateway authentication is missing."
    case .unavailable(let message, _): "OpenClaw Gateway is starting: \(message)"
    case .rejected(let message): "OpenClaw Gateway rejected the request: \(message)"
    case .unsupportedCapability(let method): "This OpenClaw Gateway does not support \(method)."
    case .requestTimedOut(let method): "OpenClaw Gateway timed out while running \(method)."
    }
  }
}

/// One native OpenClaw Gateway implementation shared by all endpoint adapters.
/// Protocol v4 transport. Method advertisements are discovery hints, not an allowlist.
public actor OpenClawGatewayClient {
  public typealias EventHandler = @Sendable (OpenClawGatewayEvent) async -> Void
  public typealias DisconnectHandler = @Sendable (String) async -> Void
  public typealias ConnectionHandler = @Sendable () async -> Void

  private struct Frame: Codable {
    var type: String
    var id: String?
    var method: String?
    var event: String?
    var params: GatewayJSONValue?
    var payload: GatewayJSONValue?
    var ok: Bool?
    var error: GatewayJSONValue?
    var seq: Int?
  }

  private let endpoint: OpenClawGatewayEndpoint
  private let requestHeaders: [String: String]
  private let password: String?
  private let eventHandler: EventHandler
  private let disconnectHandler: DisconnectHandler
  private let connectionHandler: ConnectionHandler
  private let credentialStore: any OpenClawGatewayCredentialStore
  private let credentialScope: String
  private let socketFactory: @Sendable (URLRequest) -> any OpenClawGatewaySocket
  private let handshakeTimeout: Duration
  private var socket: (any OpenClawGatewaySocket)?
  private var capabilities: OpenClawGatewayCapabilities?
  private var pending: [String: CheckedContinuation<GatewayJSONValue, any Error>] = [:]
  private var requestTimeouts: [String: Task<Void, Never>] = [:]
  private var receiver: Task<Void, Never>?
  private var connecting: Task<OpenClawGatewayCapabilities, any Error>?
  private var watchdog: Task<Void, Never>?
  private var generation = UUID()
  private var lastEventSequence: Int?
  private var lastFrameAt = ContinuousClock.now
  private var retired = false

  public var connectedGeneration: UUID? { capabilities != nil && socket != nil ? generation : nil }

  public init(
    endpoint: OpenClawGatewayEndpoint,
    requestHeaders: [String: String] = [:],
    password: String? = nil,
    credentialScope: String? = nil,
    credentialStore: any OpenClawGatewayCredentialStore = OpenClawGatewayKeychain.shared,
    eventHandler: @escaping EventHandler = { _ in },
    disconnectHandler: @escaping DisconnectHandler = { _ in },
    connectionHandler: @escaping ConnectionHandler = {}
  ) {
    self.endpoint = endpoint
    self.requestHeaders = requestHeaders
    self.password = password
    self.eventHandler = eventHandler
    self.disconnectHandler = disconnectHandler
    self.connectionHandler = connectionHandler
    self.credentialScope = credentialScope ?? endpoint.url.absoluteString
    self.credentialStore = credentialStore
    self.socketFactory = { OpenClawURLSessionSocket(request: $0) }
    self.handshakeTimeout = .seconds(15)
  }

  init(
    endpoint: OpenClawGatewayEndpoint,
    credentialStore: any OpenClawGatewayCredentialStore,
    handshakeTimeout: Duration = .seconds(15),
    socketFactory: @escaping @Sendable (URLRequest) -> any OpenClawGatewaySocket,
    eventHandler: @escaping EventHandler = { _ in }
  ) {
    self.endpoint = endpoint
    self.requestHeaders = [:]
    self.password = nil
    self.credentialScope = endpoint.url.absoluteString
    self.credentialStore = credentialStore
    self.handshakeTimeout = handshakeTimeout
    self.socketFactory = socketFactory
    self.eventHandler = eventHandler
    self.disconnectHandler = { _ in }
    self.connectionHandler = {}
  }

  public func connect() async throws -> OpenClawGatewayCapabilities {
    guard !retired else { throw OpenClawGatewayClientError.connectionClosed }
    if let capabilities, socket != nil { return capabilities }
    if let connecting { return try await connecting.value }
    let attempt = UUID()
    generation = attempt
    let task = Task { try await self.performConnect(generation: attempt) }
    connecting = task
    do {
      let hello = try await task.value
      guard generation == attempt else { throw CancellationError() }
      connecting = nil
      Task { await connectionHandler() }
      return hello
    } catch {
      if generation == attempt {
        connecting = nil
        await closeTransport()
      }
      throw error
    }
  }

  private func performConnect(generation attempt: UUID) async throws -> OpenClawGatewayCapabilities {
    guard !retired, generation == attempt, !Task.isCancelled else { throw CancellationError() }
    guard ["ws", "wss"].contains(endpoint.url.scheme?.lowercased()) else {
      throw OpenClawGatewayClientError.invalidEndpoint
    }
    var request = URLRequest(url: endpoint.url)
    for (name, value) in requestHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    // The local service explicitly rejects browser-origin WebSockets. URLSession
    // does not add Origin by default; remove any inherited value defensively.
    request.setValue(nil, forHTTPHeaderField: "Origin")
    let socket = socketFactory(request)
    self.socket = socket
    await socket.start()
    // Closing the captured socket unblocks receive even if no challenge ever arrives.
    let timeout = Task {
      do { try await Task.sleep(for: handshakeTimeout) } catch { return }
      await socket.close()
    }
    defer { timeout.cancel() }
    let challenge = try await receiveFrame(from: socket)
    guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
    guard challenge.type == "event", challenge.event == "connect.challenge",
          let nonce = challenge.payload?.objectValue?["nonce"]?.stringValue,
          !nonce.isEmpty,
          let signedAt = challenge.payload?.objectValue?["ts"]?.intValue,
          signedAt >= 0 else {
      throw OpenClawGatewayClientError.challengeMissing
    }
    var credentials = try credentialStore.credentials(for: credentialScope)
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.privateKey)
    let sharedToken = Self.bearerToken(from: requestHeaders)
    let token = sharedToken ?? (password == nil ? credentials.deviceToken : nil)
    if endpoint.authorization == .remoteWorkspace, token == nil, password == nil {
      throw OpenClawGatewayClientError.authenticationMissing
    }
    let requestID = UUID().uuidString.lowercased()
    let scopes = ["operator.read", "operator.write", "operator.admin"]
    let publicKey = signingKey.publicKey.rawRepresentation.base64URLEncodedString()
    let deviceID = SHA256.hash(data: signingKey.publicKey.rawRepresentation)
      .map { String(format: "%02x", $0) }.joined()
    let signaturePayload = Self.deviceSignaturePayload(
      deviceID: deviceID, scopes: scopes, signedAt: signedAt,
      token: token ?? "", nonce: nonce
    )
    let signature = try signingKey.signature(for: Data(signaturePayload.utf8))
      .base64URLEncodedString()
    let connectParams = Self.connectParameters(
      deviceID: deviceID, publicKey: publicKey, signature: signature,
      signedAt: signedAt, nonce: nonce, scopes: scopes, token: sharedToken,
      deviceToken: sharedToken == nil && password == nil ? credentials.deviceToken : nil, password: password
    )
    try await send(Frame(type: "req", id: requestID, method: "connect", params: connectParams))
    let response = try await receiveFrame(from: socket)
    guard response.type == "res", response.id == requestID, response.ok == true,
          let hello = response.payload else {
      throw response.error.map(Self.responseError) ?? OpenClawGatewayClientError.malformedFrame
    }
    let negotiated = try Self.capabilities(from: hello)
    guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
    if let deviceToken = hello.objectValue?["auth"]?.objectValue?["deviceToken"]?.stringValue {
      credentials.deviceToken = deviceToken
      try credentialStore.save(credentials, for: credentialScope)
    }
    capabilities = negotiated
    lastEventSequence = nil
    lastFrameAt = .now
    receiver = Task { await self.receiveLoop(from: socket, generation: attempt) }
    watchdog = Task {
      let interval = max(1_000, negotiated.tickIntervalMilliseconds)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
        guard self.generation == attempt else { return }
        if self.lastFrameAt.duration(to: .now) > .milliseconds(interval * 3) {
          await socket.close()
          return
        }
      }
    }
    return negotiated
  }

  static func deviceSignaturePayload(
    deviceID: String,
    scopes: [String],
    signedAt: Int,
    token: String = "",
    nonce: String,
    clientID: String = "gateway-client",
    clientMode: String = "backend",
    role: String = "operator",
    platform: String = "macos",
    deviceFamily: String = "desktop"
  ) -> String {
    [
      "v3", deviceID, clientID, clientMode, role,
      scopes.joined(separator: ","), String(signedAt), token, nonce,
      platform, deviceFamily,
    ].joined(separator: "|")
  }

  static func connectParameters(
    deviceID: String,
    publicKey: String,
    signature: String,
    signedAt: Int,
    nonce: String,
    scopes: [String],
    token: String? = nil,
    deviceToken: String? = nil,
    password: String? = nil
  ) -> GatewayJSONValue {
    var parameters: [String: GatewayJSONValue] = [
      "minProtocol": .number(4), "maxProtocol": .number(4),
      "client": .object([
        "id": .string("gateway-client"),
        "displayName": .string("Woven Matter"),
        "version": .string("1.0"), "platform": .string("macos"),
        "deviceFamily": .string("desktop"), "mode": .string("backend"),
      ]),
      "role": .string("operator"),
      "scopes": .array(scopes.map(GatewayJSONValue.string)),
      // OpenClaw only registers this connection as a recipient for run-scoped
      // tool lifecycle events when the client explicitly advertises this cap.
      "caps": .array([.string("tool-events"), .string("agent-kind")]),
      "commands": .array([]),
      "permissions": .object([:]),
      "device": .object([
        "id": .string(deviceID), "publicKey": .string(publicKey),
        "signature": .string(signature), "signedAt": .number(Double(signedAt)),
        "nonce": .string(nonce),
      ]),
      "locale": .string("en-US"),
      "userAgent": .string("woven-matter-macos/1.0"),
    ]
    if let token { parameters["auth"] = .object(["token": .string(token)]) }
    else if let password { parameters["auth"] = .object(["password": .string(password)]) }
    else if let deviceToken { parameters["auth"] = .object(["deviceToken": .string(deviceToken)]) }
    return .object(parameters)
  }

  static func bearerToken(from headers: [String: String]) -> String? {
    guard let value = headers.first(where: {
      $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
    })?.value else { return nil }
    let components = value.split(separator: " ", maxSplits: 1)
    guard components.count == 2,
          components[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
      return nil
    }
    let token = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
  }

  static func capabilities(from payload: GatewayJSONValue) throws -> OpenClawGatewayCapabilities {
    guard let hello = payload.objectValue,
          hello["protocol"]?.intValue == 4 else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    let features = hello["features"]?.objectValue
    let policy = hello["policy"]?.objectValue
    let attachmentPolicy = policy?["attachments"]?.objectValue.map {
      OpenClawGatewayCapabilities.AttachmentPolicy(
        maximumBytes: $0["maxBytes"]?.intValue,
        maximumImageBytes: $0["maxImageBytes"]?.intValue
      )
    }
    let methods = Set(features?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let events = Set(features?["events"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    return OpenClawGatewayCapabilities(
      applicationVersion: hello["server"]?.objectValue?["version"]?.stringValue,
      methods: methods,
      events: events,
      maximumPayloadBytes: policy?["maxPayload"]?.intValue,
      attachmentPolicy: attachmentPolicy,
      tickIntervalMilliseconds: min(300_000, max(1_000, policy?["tickIntervalMs"]?.intValue ?? 30_000))
    )
  }

  public func disconnect() async {
    // Explicit retirement (unlink/reconfigure/shutdown) is not a network outage.
    // Owners must create a new client; stale callers may never reopen this one.
    retired = true
    generation = UUID()
    connecting?.cancel()
    connecting = nil
    await closeTransport()
  }

  private func closeTransport() async {
    receiver?.cancel()
    receiver = nil
    watchdog?.cancel()
    watchdog = nil
    let previous = socket
    socket = nil
    capabilities = nil
    failPending(OpenClawGatewayClientError.connectionClosed)
    await previous?.close()
  }

  public func request(
    _ method: String,
    params: GatewayJSONValue = .object([:]),
    timeout: Duration = .seconds(30),
    expectedConnectionGeneration: UUID? = nil
  ) async throws -> GatewayJSONValue {
    if let expectedConnectionGeneration {
      guard connectedGeneration == expectedConnectionGeneration, !retired else {
        throw OpenClawGatewayClientError.rejected("The connection changed. Refresh before making a decision.")
      }
    } else { _ = try await connect() }
    try Task.checkCancellation()
    let id = UUID().uuidString.lowercased()
    let requestGeneration = generation
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      requestTimeouts[id] = Task {
        do { try await Task.sleep(for: timeout) }
        catch { return }
        self.resumePending(
          id: id,
          with: .failure(OpenClawGatewayClientError.requestTimedOut(method))
        )
      }
      Task {
        do {
          guard self.generation == requestGeneration, self.pending[id] != nil else { return }
          try await self.send(Frame(type: "req", id: id, method: method, params: params))
        }
        catch { self.resumePending(id: id, with: .failure(error)) }
      }
    }
  }

  public func sessionPreferences(key: String) async throws -> OpenClawSessionPreferences {
    let value = try await request("sessions.describe", params: .object(["key": .string(key)]))
    return Self.sessionPreferences(from: value)
  }

  static func sessionPreferences(from payload: GatewayJSONValue) -> OpenClawSessionPreferences {
    let object = payload.objectValue?["session"]?.objectValue ?? [:]
    let model = object["model"]?.stringValue
    let provider = object["modelProvider"]?.stringValue
    return OpenClawSessionPreferences(
      model: model.map { value in
        guard !value.contains("/"), let provider, !provider.isEmpty else { return value }
        return provider + "/" + value
      },
      thinkingLevel: object["thinkingLevel"]?.stringValue
    )
  }

  public func patchSession(
    key: String,
    preferences: OpenClawSessionPreferences
  ) async throws -> OpenClawSessionPreferences {
    var params: [String: GatewayJSONValue] = ["key": .string(key)]
    if let model = preferences.model { params["model"] = .string(model) }
    if let thinking = preferences.thinkingLevel { params["thinkingLevel"] = .string(thinking) }
    _ = try await request("sessions.patch", params: .object(params))
    return try await sessionPreferences(key: key)
  }

  private func receiveLoop(from socket: any OpenClawGatewaySocket, generation attempt: UUID) async {
    do {
      while !Task.isCancelled {
        let frame = try await receiveFrame(from: socket)
        guard generation == attempt else { return }
        lastFrameAt = .now
        if frame.type == "res", let id = frame.id {
          if frame.ok == true { resumePending(id: id, with: .success(frame.payload ?? .null)) }
          else { resumePending(id: id, with: .failure(frame.error.map(Self.responseError) ?? OpenClawGatewayClientError.malformedFrame)) }
        } else if frame.type == "event", let name = frame.event {
          if let seq = frame.seq {
            if let last = lastEventSequence {
              if seq <= last { continue }
              if seq != last + 1 {
                throw OpenClawGatewayClientError.unavailable("Event stream interrupted; refreshing session history.", retryAfterMilliseconds: 250)
              }
            }
            lastEventSequence = seq
          }
          await eventHandler(OpenClawGatewayEvent(name: name, payload: frame.payload, sequence: frame.seq))
        }
      }
    } catch {
      guard generation == attempt else { return }
      self.socket = nil
      capabilities = nil
      watchdog?.cancel()
      watchdog = nil
      failPending(error)
      await socket.close()
      if generation == attempt, !Task.isCancelled {
        await disconnectHandler(error.localizedDescription)
      }
    }
  }

  private func send(_ frame: Frame) async throws {
    guard let socket else { throw OpenClawGatewayClientError.connectionClosed }
    let data = try JSONEncoder().encode(frame)
    if let limit = capabilities?.maximumPayloadBytes, data.count > limit {
      throw OpenClawGatewayClientError.rejected("Request exceeds the Gateway payload limit.")
    }
    try await socket.send(data)
  }

  private func receiveFrame(from socket: any OpenClawGatewaySocket) async throws -> Frame {
    let data = try await socket.receive()
    return try JSONDecoder().decode(Frame.self, from: data)
  }

  private func resumePending(id: String, with result: Result<GatewayJSONValue, any Error>) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    requestTimeouts.removeValue(forKey: id)?.cancel()
    continuation.resume(with: result)
  }

  private func failPending(_ error: any Error) {
    let continuations = pending.values
    pending.removeAll()
    for timeout in requestTimeouts.values { timeout.cancel() }
    requestTimeouts.removeAll()
    for continuation in continuations { continuation.resume(throwing: error) }
  }

  private static func responseError(_ value: GatewayJSONValue) -> any Error {
    let object = value.objectValue ?? [:]
    let message = object["message"]?.stringValue ?? "Unknown Gateway error"
    let details = object["details"]?.objectValue ?? [:]
    let retryAfterMilliseconds = object["retryAfterMs"]?.intValue
      ?? details["retryAfterMs"]?.intValue
    if object["code"]?.stringValue == "UNAVAILABLE"
      || object["retryable"]?.boolValue == true
      || details["retryable"]?.boolValue == true {
      return OpenClawGatewayClientError.unavailable(
        message,
        retryAfterMilliseconds: retryAfterMilliseconds
      )
    }
    return OpenClawGatewayClientError.rejected(message)
  }
}

public extension OpenClawGatewayClientError {
  var retryDelay: Duration? {
    guard case .unavailable(_, let milliseconds) = self else { return nil }
    return .milliseconds(max(100, min(milliseconds ?? 1_000, 5_000)))
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
