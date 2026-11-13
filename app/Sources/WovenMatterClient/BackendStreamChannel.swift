#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import WovenMatterCore

/// One persistent connection on the background server's Unix socket: a
/// window's live stream to its own server ("Mac window to its own server" in
/// docs/architecture/WOVEN_EVERYWHERE.md). It starts as an ordinary RPC
/// connection, with the same owner-only socket and kernel peer-credential
/// check, whose first request is `StreamProtocol.unixSocketMethod`; after
/// the reply both ends exchange length-prefixed stream frames on it.
/// Bytes only: the frame format belongs to the stream.
public final class BackendStreamChannel: @unchecked Sendable {
    /// A write that cannot finish in this long means the other end stopped reading.
    public static let writeTimeout: TimeInterval = 30
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var onClose: (@Sendable () -> Void)?
    private let readQueue = DispatchQueue(label: "wovenmatter.backend.stream.read")
    private let writeQueue = DispatchQueue(label: "wovenmatter.backend.stream.write")

    /// Takes ownership of `fd`, a connected, configured and peer-checked socket.
    init(fd: Int32, onClose: (@Sendable () -> Void)? = nil) {
        self.fd = fd; self.onClose = onClose
    }

    deinit {
        close()
        Darwin.close(fd)
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// The next bytes, or nil once either end closed the connection.
    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { continuation.resume(with: Result { try self.readNow() }) }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { continuation.resume(with: Result { try self.writeNow(data) }) }
        }
    }

    /// Shuts the connection down. A read in progress returns nil; later writes fail.
    public func close() {
        let callback: (@Sendable () -> Void)?
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        callback = onClose; onClose = nil
        lock.unlock()
        // Wakes a blocked poll; the descriptor itself is released in deinit,
        // after every queued read and write has finished with it.
        shutdown(fd, PortablePOSIX.shutdownBoth)
        callback?()
    }

    private func readNow() throws -> Data? {
        var buffer = Data(count: 64 * 1024)
        while true {
            if isClosed { return nil }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // No timeout: `close()` shuts the socket down, which ends the wait.
            let ready = poll(&item, 1, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                throw BackendRPCError.unavailable
            }
            let count = buffer.count
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, count) }
            if amount < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                if isClosed { return nil }
                throw BackendRPCError.unavailable
            }
            if amount == 0 { return nil }
            return buffer.prefix(amount)
        }
    }

    private func writeNow(_ data: Data) throws {
        guard !isClosed else { throw BackendRPCError.unavailable }
        guard !data.isEmpty else { return }
        try BackendSocket.writeAll(data, fd: fd, deadline: Date().addingTimeInterval(Self.writeTimeout))
    }
}
