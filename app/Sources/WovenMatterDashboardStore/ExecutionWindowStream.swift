import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterShared

/// A Mac window's one live connection to its own background server ("Mac
/// window to its own server" in docs/architecture/WOVEN_EVERYWHERE.md): the
/// stream's frames on the background server's Unix socket, each a 4-byte
/// big-endian length and its JSON. The socket's owner-only permissions and
/// kernel peer credentials authenticate it, exactly as for every RPC there;
/// there is no upgrade or signature.
///
/// It serves `server.state` (the scopes and conversations the background
/// server invalidates) and `conversation` for any chat the window opens,
/// with the same subscription logic as a member's WebSocket. Commands stay on
/// the background service's own command call.
public final class ExecutionWindowStreamServer: @unchecked Sendable {
  public let configuration: ExecutionStreamConfiguration
  public let serverState = ExecutionServerStateFeed()
  let source: any ExecutionConversationSource
  let tail: ExecutionStreamTail
  private let database: WorkspaceDatabase
  private let hello: @Sendable () async -> StreamHello
  private let lock = NSLock()
  private var sessions: [UUID: StreamSession] = [:]
  private var observer: UUID?
  private var started = false
  private var stopped = false

  public init(database: WorkspaceDatabase, source: any ExecutionConversationSource,
              configuration: ExecutionStreamConfiguration = .init(), hello: @escaping @Sendable () async -> StreamHello) {
    self.database = database; self.source = source; self.configuration = configuration; self.hello = hello
    tail = ExecutionStreamTail(database: database)
  }

  /// Starts following this Mac's change source.
  public func start() async {
    guard lock.withLock({ () -> Bool in
      guard !started, !stopped else { return false }
      started = true; return true
    }) else { return }
    await tail.start()
    let tail = tail
    let observer = database.observeExecutionStreamChanges { _ in Task { await tail.poke() } }
    let keep = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      self.observer = observer; return true
    }
    if !keep { database.removeExecutionStreamObserver(observer) }
  }

  /// Ends every window's connection; each reconnects to the next server.
  public func stop() {
    let (observer, open) = lock.withLock { () -> (UUID?, [StreamSession]) in
      stopped = true
      defer { self.observer = nil; sessions.removeAll() }
      return (self.observer, Array(sessions.values))
    }
    if let observer { database.removeExecutionStreamObserver(observer) }
    for session in open { Task { await session.close(.goingAway) } }
  }

  /// Serves one connection the background server's socket handed over.
  public func accept(_ channel: BackendStreamChannel) {
    let context = StreamSessionContext(configuration: configuration, conversations: source, workspace: nil, members: nil,
      registry: nil, tail: tail, serverState: serverState, hello: hello, ended: { [weak self] id in
        self?.lock.withLock { _ = self?.sessions.removeValue(forKey: id) }
      })
    let session = StreamSession(context: context, wire: UnixStreamWire(channel: channel), member: nil)
    let accepted = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      sessions[session.id] = session
      return true
    }
    guard accepted else { channel.close(); return }
    Task { await session.begin() }
  }

  /// In-memory state changed for `conversationIDs` (every conversation when
  /// empty): run state, capabilities, settings, or a relayed session's live state.
  public func liveStateChanged(conversationIDs: Set<String> = []) {
    let tail = tail
    Task { await tail.publish(.live(conversationIDs)) }
  }

  /// Open window connections, for diagnostics and tests.
  public func openSessionCount() -> Int { lock.withLock { sessions.count } }
}

/// The window's Unix socket: length-prefixed frames, no control frames. A
/// closed socket ends its read, which is all the liveness it needs.
final class UnixStreamWire: ExecutionStreamWire, @unchecked Sendable {
  private let channel: BackendStreamChannel

  init(channel: BackendStreamChannel) { self.channel = channel }

  func start(_ session: StreamSession) {
    let channel = channel
    Task {
      var buffer = Data()
      while true {
        let bytes: Data?
        do { bytes = try await channel.read() } catch { _ = await session.deliver(.closed(nil)); return }
        guard let bytes else { _ = await session.deliver(.closed(nil)); return }
        buffer.append(bytes)
        let frames: [StreamFrame]
        do { frames = try StreamProtocol.takeLengthPrefixedFrames(from: &buffer) }
        catch { _ = await session.deliver(.closed(.protocolViolation)); return }
        for frame in frames { guard await session.deliver(.frame(frame)) else { return } }
      }
    }
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    var length = UInt32(data.count).bigEndian
    var framed = Data(bytes: &length, count: StreamProtocol.lengthPrefixBytes)
    framed.append(data)
    let channel = channel
    Task {
      do { try await channel.write(framed); completion(true) } catch { completion(false) }
    }
  }

  var pings: Bool { false }
  func ping(_ pong: @escaping @Sendable () -> Void) {}

  func close(_ code: StreamProtocol.CloseCode?) { channel.close() }
}
