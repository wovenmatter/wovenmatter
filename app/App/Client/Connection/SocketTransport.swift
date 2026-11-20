import Foundation
import Network
import Synchronization
import WovenProtocol

/// Where a server is: this Mac's over its Unix socket, another machine's at
/// its tailnet address.
enum ServerEndpoint: Hashable, Sendable, CustomStringConvertible {
    case unix(path: String)
    case tcp(host: String, port: Int)

    var description: String {
        switch self {
        case .unix(let path): path
        case .tcp(let host, let port): "\(host):\(port)"
        }
    }
}

/// One WebSocket connection to a server, carrying protocol messages as text
/// frames. Network.framework's own WebSocket does not run over a Unix socket,
/// so this speaks the small client side of RFC 6455 over a plain stream.
final class SocketTransport: MessageTransport, Sendable {
    let incoming: AsyncThrowingStream<String, any Error>

    private struct State {
        var buffer = Data()
        var fragments = Data()
        var isClosed = false
        var lastReceived = ContinuousClock.now
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private static let maximumMessageSize = 64 << 20
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let received: AsyncThrowingStream<String, any Error>.Continuation
    private let state = Mutex(State())

    private init(connection: NWConnection, queue: DispatchQueue, leftover: Data) {
        let (incoming, received) = AsyncThrowingStream<String, any Error>.makeStream()
        self.incoming = incoming
        self.received = received
        self.connection = connection
        self.queue = queue
        state.withLock { $0.buffer = leftover }
    }

    /// Connects, upgrades to WebSocket and starts reading. Fails within
    /// `timeout` when nothing answers.
    static func connect(_ endpoint: ServerEndpoint, timeout: Duration = .seconds(5)) async throws -> SocketTransport {
        let target: NWEndpoint = switch endpoint {
        case .unix(let path): .unix(path: path)
        case .tcp(let host, let port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        }
        let queue = DispatchQueue(label: "woven.socket")
        let connection = NWConnection(to: target, using: .tcp)
        do {
            try await ready(connection, queue: queue, timeout: timeout)
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let request = "GET / HTTP/1.1\r\nHost: woven\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            try await write(Data(request.utf8), on: connection)
            let leftover = try await readUpgrade(connection, timeout: timeout)
            let transport = SocketTransport(connection: connection, queue: queue, leftover: leftover)
            transport.start()
            return transport
        } catch {
            connection.cancel()
            throw error
        }
    }

    func send(_ text: String) throws {
        guard !state.withLock({ $0.isClosed }) else { throw ConnectionClosed() }
        connection.send(content: Self.frame(opcode: 0x1, payload: Data(text.utf8)), completion: .contentProcessed { _ in })
    }

    func close() {
        guard !state.withLock({ $0.isClosed }) else { return }
        connection.send(content: Self.frame(opcode: 0x8, payload: Data([0x03, 0xE8])), isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
        finish(nil)
    }

    /// Returns once the connection has closed, from either side.
    func closed() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                if state.isClosed { return true }
                state.closeWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    // MARK: Reading

    private func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        queue.async { [weak self] in self?.parse() }
        receive()
        keepAlive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                state.withLock {
                    $0.buffer.append(data)
                    $0.lastReceived = .now
                }
                parse()
            }
            if let error { return finish(error) }
            if isComplete { return finish(nil) }
            receive()
        }
    }

    /// Pings every 15 seconds; a connection silent for 45 seconds is dead.
    private func keepAlive() {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !state.withLock({ $0.isClosed }) else { return }
            if ContinuousClock.now - state.withLock({ $0.lastReceived }) > .seconds(45) {
                connection.cancel()
                return finish(ConnectionClosed())
            }
            connection.send(content: Self.frame(opcode: 0x9, payload: Data()), completion: .contentProcessed { _ in })
            keepAlive()
        }
    }

    /// Takes every whole frame out of the buffer.
    private func parse() {
        while true {
            let next: (opcode: UInt8, fin: Bool, payload: Data)? = state.withLock { state in
                guard let (frame, length) = Self.frame(in: state.buffer) else { return nil }
                state.buffer.removeFirst(length)
                return frame
            }
            guard let next else { return }
            switch next.opcode {
            case 0x0, 0x1, 0x2:
                let message: Data? = state.withLock { state in
                    state.fragments.append(next.payload)
                    guard next.fin else { return nil }
                    defer { state.fragments = Data() }
                    return state.fragments
                }
                if state.withLock({ $0.fragments.count }) > Self.maximumMessageSize { return fail() }
                if let message { received.yield(String(decoding: message, as: UTF8.self)) }
            case 0x8:
                connection.cancel()
                return finish(nil)
            case 0x9:
                connection.send(content: Self.frame(opcode: 0xA, payload: next.payload), completion: .contentProcessed { _ in })
            default:
                continue
            }
        }
    }

    private func fail() {
        connection.cancel()
        finish(ConnectionClosed())
    }

    private func finish(_ error: (any Error)?) {
        let waiters: [CheckedContinuation<Void, Never>]? = state.withLock { state in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            defer { state.closeWaiters = [] }
            return state.closeWaiters
        }
        guard let waiters else { return }
        if let error { received.finish(throwing: error) } else { received.finish() }
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Frames

    /// A masked client frame.
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65536:
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)])
        default:
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8(UInt64(payload.count) >> (8 * UInt64($0)) & 0xFF) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// The first whole frame in `buffer` and how many bytes it took, or nil
    /// when more bytes are needed.
    private static func frame(in buffer: Data) -> ((opcode: UInt8, fin: Bool, payload: Data), Int)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = UInt64(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard UInt64(buffer.count - offset) >= length else { return nil }
        let start = buffer.startIndex + offset
        var payload = Data(buffer[start..<start + Int(length)])
        if masked {
            for index in payload.indices { payload[index] ^= mask[(index - payload.startIndex) % 4] }
        }
        return ((opcode, fin, payload), offset + Int(length))
    }

    // MARK: Connecting

    private static func ready(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration) async throws {
        let once = Mutex<CheckedContinuation<Void, any Error>?>(nil)
        let resume: @Sendable (Result<Void, any Error>) -> Void = { result in
            once.withLock { $0.take() }?.resume(with: result)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.withLock { $0 = continuation }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(.success(()))
                case .failed(let error), .waiting(let error): resume(.failure(error))
                case .cancelled: resume(.failure(ConnectionClosed()))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                resume(.failure(ConnectionClosed()))
            }
        }
        connection.stateUpdateHandler = nil
    }

    private static func write(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Reads the server's answer to the upgrade; returns any bytes after it.
    private static func readUpgrade(_ connection: NWConnection, timeout: Duration) async throws -> Data {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            guard data.count < 16384 else { throw ProtocolError(.refused, "The server did not accept a WebSocket connection.") }
            data.append(try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, isComplete, error in
                    if let error { return continuation.resume(throwing: error) }
                    if let chunk, !chunk.isEmpty { return continuation.resume(returning: chunk) }
                    continuation.resume(throwing: isComplete ? ConnectionClosed() : ProtocolError(.failed, "Nothing arrived."))
                }
            })
        }
        let end = data.range(of: separator)!
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 101") else {
            throw ProtocolError(.refused, "The server did not accept a WebSocket connection.")
        }
        return Data(data[end.upperBound...])
    }
}
