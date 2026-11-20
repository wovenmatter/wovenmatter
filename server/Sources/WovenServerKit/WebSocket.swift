import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import WovenProtocol

/// Where a server listens or a client connects.
public enum Endpoint: Sendable, Hashable {
  /// A Unix socket, for the UI on the same machine. File permissions protect it.
  case unix(path: String)
  /// A TCP address, for other machines on the tailnet.
  case tcp(host: String, port: Int)
}

/// The largest message either side accepts. Sync pages stay well below it.
let maximumMessageSize = 64 << 20

/// The most bytes a connection queues for sending. A peer that does not read
/// what it is sent is disconnected rather than allowed to grow memory.
let maximumQueuedBytes = 2 * maximumMessageSize

/// A frame waiting to be written; `waiter` names who waits for it.
private struct Outgoing: Sendable {
  let frame: WebSocketFrame
  let waiter: UInt64?
}

/// Senders waiting for their frames to be written. Whatever is still waiting
/// when the connection ends is told it was not.
private final class Waiters: Sendable {
  private let state = Mutex<(next: UInt64, open: Bool, waiting: [UInt64: @Sendable (Bool) -> Void])>((0, true, [:]))

  func add(_ waiter: @escaping @Sendable (Bool) -> Void) -> UInt64? {
    state.withLock { state in
      guard state.open else { return nil }
      state.next += 1
      state.waiting[state.next] = waiter
      return state.next
    }
  }

  func done(_ id: UInt64?, _ written: Bool) {
    guard let id else { return }
    state.withLock { $0.waiting.removeValue(forKey: id) }?(written)
  }

  func endAll() {
    let all = state.withLock { state in
      state.open = false
      defer { state.waiting.removeAll() }
      return Array(state.waiting.values)
    }
    for waiter in all { waiter(false) }
  }
}

/// Bytes waiting to be written.
private final class Counter: Sendable {
  private let value = Mutex<Int>(0)
  func withLock<T>(_ body: (inout Int) -> T) -> T { value.withLock { body(&$0) } }
}

/// One WebSocket connection carrying protocol messages as text frames.
final class WebSocketTransport: MessageTransport {
  let incoming: AsyncThrowingStream<String, any Error>
  private let outbound: AsyncStream<Outgoing>.Continuation
  private let masked: Bool
  private let queued = Counter()
  private let waiters = Waiters()

  init(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, isClient: Bool) {
    let (incoming, received) = AsyncThrowingStream<String, any Error>.makeStream()
    let (frames, outbound) = AsyncStream<Outgoing>.makeStream()
    self.incoming = incoming
    self.outbound = outbound
    self.masked = isClient
    let masked = isClient
    let queued = queued
    let waiters = waiters
    Task {
      do {
        try await channel.executeThenClose { inbound, writer in
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              for await outgoing in frames {
                queued.withLock { $0 -= outgoing.frame.length }
                do {
                  try await writer.write(outgoing.frame)
                  waiters.done(outgoing.waiter, true)
                } catch {
                  waiters.done(outgoing.waiter, false)
                  throw error
                }
              }
              var reason = ByteBuffer()
              reason.write(webSocketErrorCode: .normalClosure)
              let close = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: masked ? .random() : nil, data: reason)
              try? await writer.write(close)
            }
            group.addTask {
              for try await frame in inbound {
                switch frame.opcode {
                case .text:
                  received.yield(String(buffer: frame.unmaskedData))
                case .ping:
                  outbound.yield(Outgoing(frame: WebSocketFrame(fin: true, opcode: .pong, maskKey: masked ? .random() : nil,
                                                                data: frame.unmaskedData), waiter: nil))
                case .connectionClose:
                  return
                default:
                  continue
                }
              }
            }
            // Whichever side ends first ends the connection.
            _ = try await group.next()
            group.cancelAll()
          }
        }
        received.finish()
      } catch {
        received.finish(throwing: error)
      }
      outbound.finish()
      waiters.endAll()
    }
  }

  func send(_ text: String) throws {
    guard enqueue(text, waiter: nil) else { throw ConnectionClosed() }
  }

  func sendWhenWritten(_ text: String) async throws {
    let written: Bool = await withCheckedContinuation { continuation in
      guard let waiter = waiters.add({ continuation.resume(returning: $0) }) else {
        continuation.resume(returning: false)
        return
      }
      _ = enqueue(text, waiter: waiter)
    }
    if !written { throw ConnectionClosed() }
  }

  /// Queues a frame; false when the connection is closed or over its limit.
  /// A waiter is told either way.
  private func enqueue(_ text: String, waiter: UInt64?) -> Bool {
    let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: masked ? .random() : nil, data: ByteBuffer(string: text))
    let over = queued.withLock { total in
      total += frame.length
      return total > maximumQueuedBytes
    }
    if over {
      waiters.done(waiter, false)
      close()
      return false
    }
    if case .terminated = outbound.yield(Outgoing(frame: frame, waiter: waiter)) {
      waiters.done(waiter, false)
      return false
    }
    return true
  }

  func close() {
    outbound.finish()
  }
}

private enum Upgrade: Sendable {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, peer: String?)
  case notUpgraded
}

private func addAggregator(_ channel: any Channel) throws {
  try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
    minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16, maxAccumulatedFrameSize: maximumMessageSize))
}

/// A listening socket that hands each accepted WebSocket to `accept`.
final class Listener: Sendable {
  /// The TCP port it is bound to, when it is a TCP listener.
  let port: Int?
  private let channel: any Channel
  private let task: Task<Void, Never>

  private init(port: Int?, channel: any Channel, task: Task<Void, Never>) {
    self.port = port
    self.channel = channel
    self.task = task
  }

  static func start(_ endpoint: Endpoint,
                    accept: @escaping @Sendable (WebSocketTransport, _ peerAddress: String?) async -> Void) async throws -> Listener {
    let initializer: @Sendable (any Channel) -> EventLoopFuture<EventLoopFuture<Upgrade>> = { channel in
      let peer: String? = if case .unixDomainSocket = channel.remoteAddress { nil } else { channel.remoteAddress?.ipAddress ?? "" }
      return channel.eventLoop.makeCompletedFuture {
        let upgrader = NIOTypedWebSocketServerUpgrader<Upgrade>(
          maxFrameSize: maximumMessageSize,
          shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
          upgradePipelineHandler: { channel, _ in
            channel.eventLoop.makeCompletedFuture {
              try addAggregator(channel)
              return Upgrade.websocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel), peer: peer)
            }
          })
        return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
          configuration: .init(upgradeConfiguration: .init(upgraders: [upgrader], notUpgradingCompletionHandler: { channel in
            channel.close(promise: nil)
            return channel.eventLoop.makeSucceededFuture(Upgrade.notUpgraded)
          })))
      }
    }
    let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    let server: NIOAsyncChannel<EventLoopFuture<Upgrade>, Never>
    switch endpoint {
    case .unix(let path):
      server = try await bootstrap.bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true,
                                        childChannelInitializer: initializer)
      chmod(path, 0o600)
    case .tcp(let host, let port):
      server = try await bootstrap.bind(host: host, port: port, childChannelInitializer: initializer)
    }
    let task = Task<Void, Never> {
      _ = try? await server.executeThenClose { inbound in
        try await withThrowingDiscardingTaskGroup { group in
          for try await upgrade in inbound {
            group.addTask {
              guard case .websocket(let channel, let peer) = try? await upgrade.get() else { return }
              await accept(WebSocketTransport(channel: channel, isClient: false), peer)
            }
          }
        }
      }
    }
    return Listener(port: server.channel.localAddress?.port, channel: server.channel, task: task)
  }

  /// Stops accepting. Open connections are closed by their owners.
  func stop() async {
    try? await channel.close()
    task.cancel()
  }
}

private enum ClientUpgrade: Sendable {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded
}

/// Opens a WebSocket connection to a server.
public func connectWebSocket(_ endpoint: Endpoint) async throws -> any MessageTransport {
  let initializer: @Sendable (any Channel) -> EventLoopFuture<EventLoopFuture<ClientUpgrade>> = { channel in
    channel.eventLoop.makeCompletedFuture {
      let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgrade>(
        maxFrameSize: maximumMessageSize,
        upgradePipelineHandler: { channel, _ in
          channel.eventLoop.makeCompletedFuture {
            try addAggregator(channel)
            return ClientUpgrade.websocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
          }
        })
      var headers = HTTPHeaders()
      headers.add(name: "Host", value: "woven")
      headers.add(name: "Content-Length", value: "0")
      let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
      let upgrade = NIOTypedHTTPClientUpgradeConfiguration<ClientUpgrade>(
        upgradeRequestHead: head, upgraders: [upgrader],
        notUpgradingCompletionHandler: { channel in channel.eventLoop.makeSucceededFuture(ClientUpgrade.notUpgraded) })
      return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
        configuration: .init(upgradeConfiguration: upgrade))
    }
  }
  let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.seconds(5))
  let negotiated: EventLoopFuture<ClientUpgrade>
  switch endpoint {
  case .unix(let path):
    negotiated = try await bootstrap.connect(unixDomainSocketPath: path, channelInitializer: initializer)
  case .tcp(let host, let port):
    negotiated = try await bootstrap.connect(host: host, port: port, channelInitializer: initializer)
  }
  guard case .websocket(let channel) = try await negotiated.get() else {
    throw ProtocolError(.refused, "The server did not accept a WebSocket connection.")
  }
  return WebSocketTransport(channel: channel, isClient: true)
}
