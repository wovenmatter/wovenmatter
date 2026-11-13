import Foundation

/// The live stream between a user interface (or another server) and one Woven
/// server. See "Streaming" in docs/architecture/WOVEN_EVERYWHERE.md. The same
/// frames travel on a member-signed WebSocket (`GET /v1/stream?protocol=1`)
/// and, from a Mac window to its own server, on the length-prefixed Unix socket.
public enum StreamProtocol {
  public static let version = 1
  public static let supportedVersions = [1]
  /// Relative to a server's endpoint (a Mac's `/wovenmatter`, a Linux host's
  /// execution endpoint). The signed target includes the query.
  public static let path = "v1/stream"
  public static let query = "protocol=1"
  public static let capability = "stream.v1"
  public static let maximumFrameBytes = 8 * 1_024 * 1_024
  /// Unix-socket frames carry this many big-endian length bytes before the JSON.
  public static let lengthPrefixBytes = 4
  public static let pingInterval: Duration = .seconds(25)
  public static let pongTimeout: Duration = .seconds(60)
  public static let reconnectInitial: Duration = .seconds(1)
  public static let reconnectMaximum: Duration = .seconds(30)
  /// Changes to one conversation are sent at most this often while every
  /// changed message is at most `smallMessageBytes`, and `largeMessageInterval`
  /// once one is larger.
  public static let smallMessageBytes = 8 * 1_024
  public static let smallMessageInterval: Duration = .milliseconds(50)
  public static let largeMessageInterval: Duration = .milliseconds(200)
  /// `library` items on a `workspace` subscription are sent at most this often.
  public static let libraryInterval: Duration = .milliseconds(300)
  public static let maximumQueuedItems = 512
  public static let maximumQueuedBytes = 8 * 1_024 * 1_024
  /// Pointer entries the Mac keeps in `execution_stream_changes`.
  public static let maximumRetainedChanges = 10_000
  /// The longest `woven_sessions_wait` waits, below harness tool-call limits.
  public static let maximumWaitSeconds = 50
  /// The first request on a Mac's background-server Unix socket that turns
  /// that connection into the persistent length-prefixed stream.
  public static let unixSocketMethod = "backend.stream"
  /// Wake-ups one calling run (and the runs its wake-ups start) receives; see
  /// `SessionWakeUp`.
  public static let maximumWakeUpsPerRun = 10

  public enum CloseCode: Int, Sendable {
    case normal = 1000
    case goingAway = 1001
    case protocolViolation = 4400
    /// The member was removed. Do not reconnect until the member list changes.
    case memberRemoved = 4401
  }

  public enum Stream: String, Codable, Sendable {
    case workspace
    case conversation
    /// Mac window to its own server only.
    case serverState = "server.state"
  }

  public enum Method: String, Codable, Sendable {
    case executionCommand = "execution.command"
    case executionReceipt = "execution.receipt"
  }

  public enum ErrorCode: String, Codable, Sendable {
    case unauthorized, notFound = "not_found", invalid, unavailable, conflict, resync
    /// HTTP refusals before an upgrade.
    case protocolUnsupported = "protocol_unsupported", memberTimeStale = "member_time_stale"
  }

  public static func encode(_ frame: StreamFrame) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(frame)
    guard data.count <= maximumFrameBytes else { throw StreamProtocolError.frameTooLarge(data.count) }
    return data
  }

  public static func decode(_ data: Data) throws -> StreamFrame {
    guard data.count <= maximumFrameBytes else { throw StreamProtocolError.frameTooLarge(data.count) }
    return try JSONDecoder().decode(StreamFrame.self, from: data)
  }

  /// One Unix-socket frame: a 4-byte big-endian length, then the JSON.
  public static func lengthPrefixed(_ frame: StreamFrame) throws -> Data {
    let body = try encode(frame)
    var length = UInt32(body.count).bigEndian
    var data = Data(bytes: &length, count: lengthPrefixBytes)
    data.append(body)
    return data
  }

  /// Splits complete length-prefixed frames off the front of `buffer`.
  public static func takeLengthPrefixedFrames(from buffer: inout Data) throws -> [StreamFrame] {
    var frames: [StreamFrame] = []
    while buffer.count >= lengthPrefixBytes {
      let start = buffer.startIndex
      let length = buffer[start..<start + lengthPrefixBytes].reduce(0) { ($0 << 8) | Int($1) }
      guard length <= maximumFrameBytes else { throw StreamProtocolError.frameTooLarge(length) }
      guard buffer.count >= lengthPrefixBytes + length else { break }
      let body = buffer[(start + lengthPrefixBytes)..<(start + lengthPrefixBytes + length)]
      frames.append(try decode(Data(body)))
      buffer.removeSubrange(start..<(start + lengthPrefixBytes + length))
    }
    return frames
  }
}

public enum StreamProtocolError: Error, Equatable, Sendable {
  case frameTooLarge(Int)
  case unknownFrame(String)
}

public struct StreamError: Codable, Equatable, Error, Sendable {
  public var code: String
  public var message: String
  public var retryable: Bool
  public init(code: String, message: String, retryable: Bool = false) {
    self.code = code; self.message = message; self.retryable = retryable
  }
  public init(_ code: StreamProtocol.ErrorCode, _ message: String, retryable: Bool = false) {
    self.init(code: code.rawValue, message: message, retryable: retryable)
  }
}

public struct StreamHello: Codable, Equatable, Sendable {
  public var `protocol`: Int
  public var deviceID: String
  public var libraryID: String
  public var workspaceID: String
  public var serverTime: Int64
  public var capabilities: [String]
  public var maxFrameBytes: Int
  public init(protocol: Int = StreamProtocol.version, deviceID: String, libraryID: String, workspaceID: String,
              serverTime: Int64, capabilities: [String] = [], maxFrameBytes: Int = StreamProtocol.maximumFrameBytes) {
    self.protocol = `protocol`; self.deviceID = deviceID; self.libraryID = libraryID; self.workspaceID = workspaceID
    self.serverTime = serverTime; self.capabilities = capabilities; self.maxFrameBytes = maxFrameBytes
  }
}

public struct StreamRequest: Codable, Equatable, Sendable {
  public var id: String
  public var method: String
  public var params: JSONValue
  public init(id: String, method: String, params: JSONValue = .object([:])) {
    self.id = id; self.method = method; self.params = params
  }
  public init<Params: Encodable>(id: String, method: StreamProtocol.Method, params: Params) throws {
    self.init(id: id, method: method.rawValue, params: try JSONValue(encoding: params))
  }
  public func decodeParams<Params: Decodable>(_ type: Params.Type) throws -> Params { try params.decode(type) }
}

public struct StreamResponse: Codable, Equatable, Sendable {
  public var id: String
  public var result: JSONValue?
  public var error: StreamError?
  public init(id: String, result: JSONValue? = nil, error: StreamError? = nil) {
    self.id = id; self.result = result; self.error = error
  }
  public init<Result: Encodable>(id: String, encoding result: Result) throws {
    self.init(id: id, result: try JSONValue(encoding: result))
  }
  public func decodeResult<Result: Decodable>(_ type: Result.Type) throws -> Result {
    if let error { throw error }
    return try (result ?? .null).decode(type)
  }
  private enum CodingKeys: String, CodingKey { case id, result, error }
  /// A success always carries `result`, `null` included; a failure carries `error`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    if let error { try container.encode(error, forKey: .error) }
    else { try container.encode(result ?? .null, forKey: .result) }
  }
}

public struct StreamSubscribe: Codable, Equatable, Sendable {
  public var id: String
  public var stream: String
  public var params: StreamSubscribeParams
  public init(id: String, stream: StreamProtocol.Stream, params: StreamSubscribeParams = .init()) {
    self.id = id; self.stream = stream.rawValue; self.params = params
  }
}

public struct StreamSubscribeParams: Codable, Equatable, Sendable {
  /// `workspace`: the last journal `originSequence` the client holds, which
  /// requests a journal replay after it. Omitted: no journal items.
  public var after: Int64?
  /// `conversation`: the open chat.
  public var conversationID: String?
  public init(after: Int64? = nil, conversationID: String? = nil) {
    self.after = after; self.conversationID = conversationID
  }
}

public struct StreamEnd: Codable, Equatable, Sendable {
  public var id: String
  public var error: StreamError?
  public init(id: String, error: StreamError? = nil) { self.id = id; self.error = error }
}

public struct StreamCancel: Codable, Equatable, Sendable {
  public var id: String
  public init(id: String) { self.id = id }
}

public struct StreamConversations: Codable, Equatable, Sendable {
  public var conversations: [LibraryConversation]
  public var deletedConversationIDs: [String]?
  public var snapshot: Bool
  public init(conversations: [LibraryConversation], deletedConversationIDs: [String]? = nil, snapshot: Bool) {
    self.conversations = conversations; self.deletedConversationIDs = deletedConversationIDs; self.snapshot = snapshot
  }
}

public struct StreamPending: Codable, Equatable, Sendable {
  public var interactions: [PendingInteraction]
  public init(interactions: [PendingInteraction]) { self.interactions = interactions }
}

public struct StreamJournal: Codable, Equatable, Sendable {
  public var entry: ExecutionJournalEntry
  public init(entry: ExecutionJournalEntry) { self.entry = entry }
}

public struct StreamTranscript: Codable, Equatable, Sendable {
  public var transcript: LibraryTranscript
  public var snapshot: Bool
  public init(transcript: LibraryTranscript, snapshot: Bool) { self.transcript = transcript; self.snapshot = snapshot }
}

public struct StreamCapabilities: Codable, Equatable, Sendable {
  public var capabilities: HarnessCapabilities
  public init(capabilities: HarnessCapabilities) { self.capabilities = capabilities }
}

public struct StreamSession: Codable, Equatable, Sendable {
  public var settings: SessionSettings
  public init(settings: SessionSettings) { self.settings = settings }
}

/// One change the Mac's background server tells its windows about (`server.state`).
public struct StreamServerState: Codable, Equatable, Sendable {
  /// Invalidated scopes, as the background server names them.
  public var scopes: [String]
  /// Conversations whose rows changed: the window reads them again from its
  /// projection unless it follows them on a `conversation` subscription.
  public var conversationIDs: [String]?
  public init(scopes: [String], conversationIDs: [String]? = nil) { self.scopes = scopes; self.conversationIDs = conversationIDs }
}

/// The server's mobile library change cursor (the phone's `GET v1/changes`
/// feed, `device_sync_changes`): on a `workspace` subscription, on subscribe
/// and whenever the feed advances with a change a phone syncs, at most every
/// `StreamProtocol.libraryInterval`. A phone that holds this server's library
/// at an older cursor synchronizes it at once. Changes that only rewrite
/// transcripts (which the open chat streams) or the agent list do not
/// advance it, so `cursor` may trail the feed's newest entry.
public struct StreamLibrary: Codable, Equatable, Sendable {
  public var cursor: Int64
  public init(cursor: Int64) { self.cursor = cursor }
}

/// Whether the server reaches the machine that runs a session. Sent only on a
/// Mac window's socket, on `conversation` subscriptions to sessions another
/// machine runs: on subscribe and when it changes.
public struct StreamOwner: Codable, Equatable, Sendable {
  public var online: Bool
  public var error: String?
  public init(online: Bool, error: String? = nil) { self.online = online; self.error = error }
}

public struct StreamItem: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case conversations, pending, journal, transcript, capabilities, session, owner, library, synchronized
    case serverState = "server.state"
  }

  public enum Payload: Equatable, Sendable {
    case conversations(StreamConversations)
    case pending(StreamPending)
    case journal(StreamJournal)
    case transcript(StreamTranscript)
    case capabilities(StreamCapabilities)
    case session(StreamSession)
    case owner(StreamOwner)
    case library(StreamLibrary)
    case synchronized
    case serverState(StreamServerState)
    /// A kind this build does not know. Ignored, but a `seq` still advances.
    case unknown(kind: String, data: JSONValue)

    public var kind: String {
      switch self {
      case .conversations: Kind.conversations.rawValue
      case .pending: Kind.pending.rawValue
      case .journal: Kind.journal.rawValue
      case .transcript: Kind.transcript.rawValue
      case .capabilities: Kind.capabilities.rawValue
      case .session: Kind.session.rawValue
      case .owner: Kind.owner.rawValue
      case .library: Kind.library.rawValue
      case .synchronized: Kind.synchronized.rawValue
      case .serverState: Kind.serverState.rawValue
      case .unknown(let kind, _): kind
      }
    }
  }

  public var id: String
  public var seq: Int64?
  public var payload: Payload

  public init(id: String, seq: Int64? = nil, payload: Payload) { self.id = id; self.seq = seq; self.payload = payload }

  private enum CodingKeys: String, CodingKey { case id, seq, kind, data }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    seq = try container.decodeIfPresent(Int64.self, forKey: .seq)
    let kind = try container.decode(String.self, forKey: .kind)
    switch Kind(rawValue: kind) {
    case .conversations: payload = .conversations(try container.decode(StreamConversations.self, forKey: .data))
    case .pending: payload = .pending(try container.decode(StreamPending.self, forKey: .data))
    case .journal: payload = .journal(try container.decode(StreamJournal.self, forKey: .data))
    case .transcript: payload = .transcript(try container.decode(StreamTranscript.self, forKey: .data))
    case .capabilities: payload = .capabilities(try container.decode(StreamCapabilities.self, forKey: .data))
    case .session: payload = .session(try container.decode(StreamSession.self, forKey: .data))
    case .owner: payload = .owner(try container.decode(StreamOwner.self, forKey: .data))
    case .library: payload = .library(try container.decode(StreamLibrary.self, forKey: .data))
    case .synchronized: payload = .synchronized
    case .serverState: payload = .serverState(try container.decode(StreamServerState.self, forKey: .data))
    case nil: payload = .unknown(kind: kind, data: try container.decodeIfPresent(JSONValue.self, forKey: .data) ?? .null)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(seq, forKey: .seq)
    try container.encode(payload.kind, forKey: .kind)
    switch payload {
    case .conversations(let value): try container.encode(value, forKey: .data)
    case .pending(let value): try container.encode(value, forKey: .data)
    case .journal(let value): try container.encode(value, forKey: .data)
    case .transcript(let value): try container.encode(value, forKey: .data)
    case .capabilities(let value): try container.encode(value, forKey: .data)
    case .session(let value): try container.encode(value, forKey: .data)
    case .owner(let value): try container.encode(value, forKey: .data)
    case .library(let value): try container.encode(value, forKey: .data)
    case .synchronized: try container.encode([String: String](), forKey: .data)
    case .serverState(let value): try container.encode(value, forKey: .data)
    case .unknown(_, let data): try container.encode(data, forKey: .data)
    }
  }
}

public enum StreamFrame: Equatable, Sendable {
  case hello(StreamHello)
  case request(StreamRequest)
  case response(StreamResponse)
  case subscribe(StreamSubscribe)
  case item(StreamItem)
  case end(StreamEnd)
  case cancel(StreamCancel)
  /// A frame type this build does not know. Ignored.
  case unknown(String)
}

extension StreamFrame: Codable {
  private enum TypeKey: String, CodingKey { case t }
  private enum FrameType: String { case hello, req, res, sub, item, end, cancel }

  public init(from decoder: any Decoder) throws {
    let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .t)
    switch FrameType(rawValue: type) {
    case .hello: self = .hello(try StreamHello(from: decoder))
    case .req: self = .request(try StreamRequest(from: decoder))
    case .res: self = .response(try StreamResponse(from: decoder))
    case .sub: self = .subscribe(try StreamSubscribe(from: decoder))
    case .item: self = .item(try StreamItem(from: decoder))
    case .end: self = .end(try StreamEnd(from: decoder))
    case .cancel: self = .cancel(try StreamCancel(from: decoder))
    case nil: self = .unknown(type)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: TypeKey.self)
    switch self {
    case .hello(let value): try container.encode(FrameType.hello.rawValue, forKey: .t); try value.encode(to: encoder)
    case .request(let value): try container.encode(FrameType.req.rawValue, forKey: .t); try value.encode(to: encoder)
    case .response(let value): try container.encode(FrameType.res.rawValue, forKey: .t); try value.encode(to: encoder)
    case .subscribe(let value): try container.encode(FrameType.sub.rawValue, forKey: .t); try value.encode(to: encoder)
    case .item(let value): try container.encode(FrameType.item.rawValue, forKey: .t); try value.encode(to: encoder)
    case .end(let value): try container.encode(FrameType.end.rawValue, forKey: .t); try value.encode(to: encoder)
    case .cancel(let value): try container.encode(FrameType.cancel.rawValue, forKey: .t); try value.encode(to: encoder)
    case .unknown(let type): throw StreamProtocolError.unknownFrame(type)
    }
  }
}

public struct StreamCommandParams: Codable, Equatable, Sendable {
  public var command: LibraryCommand
  public init(command: LibraryCommand) { self.command = command }
}

public struct StreamReceiptParams: Codable, Equatable, Sendable {
  public var commandID: String
  public init(commandID: String) { self.commandID = commandID }
}

public extension JSONValue {
  init<Value: Encodable>(encoding value: Value) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
  func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}
