#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import WovenMatterCore

/// Serves `SSHSigningAgent` on a Unix socket only this user can open: `SSH_AUTH_SOCK` for
/// Settings → GitHub (`IdentityAgent` in its `github.conf`). Agent framing is the backend
/// socket's own: a 4-byte big-endian length, then the message.
public final class SSHAgentSocketServer: @unchecked Sendable {
    public let socketURL: URL
    private let reply: @Sendable (Data) -> Data
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var generation = UUID()
    private let slots = DispatchSemaphore(value: 16)

    public init(socketURL: URL, reply: @escaping @Sendable (Data) -> Data) {
        self.socketURL = socketURL
        self.reply = reply
    }
    deinit { stop() }

    public var isRunning: Bool { lock.withLock { descriptor >= 0 } && FileManager.default.fileExists(atPath: socketURL.path) }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == -1 else { return }
        unlink(socketURL.path)
        let fd = try BackendSocket.make()
        var succeeded = false
        defer { if !succeeded { Darwin.close(fd) } }
        var address = try BackendSocket.address(socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw BackendRPCError.invalidEndpoint }
        guard chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else { unlink(socketURL.path); throw BackendRPCError.unavailable }
        descriptor = fd; succeeded = true
        let started = UUID(); generation = started
        DispatchQueue(label: "wovenmatter.github.agent.accept").async { [weak self] in
            while let self, self.running(fd, started) {
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&item, 1, 250) > 0 else { continue }
                self.lock.lock()
                let client = self.descriptor == fd && self.generation == started ? accept(fd, nil, nil) : -1
                self.lock.unlock()
                guard client >= 0 else { continue }
                guard self.slots.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { Darwin.close(client); self.slots.signal() }
                    guard (try? BackendSocket.configure(client)) != nil, (try? BackendSocket.authenticate(client)) != nil else { return }
                    // One connection carries any number of requests; an idle one is closed.
                    while let message = Self.readMessage(client) {
                        guard (try? BackendSocket.writeFrame(self.reply(message), fd: client, deadline: Date().addingTimeInterval(10))) != nil else { return }
                    }
                }
            }
        }
    }

    /// One request, its length checked before anything else is read.
    private static func readMessage(_ fd: Int32) -> Data? {
        guard let header = try? BackendSocket.read(4, fd: fd, deadline: Date().addingTimeInterval(60)) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= SSHSigningAgent.maximumMessage else { return nil }
        return try? BackendSocket.read(length, fd: fd, deadline: Date().addingTimeInterval(10))
    }

    private func running(_ fd: Int32, _ expected: UUID) -> Bool { lock.withLock { descriptor == fd && generation == expected } }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, PortablePOSIX.shutdownBoth); Darwin.close(descriptor); descriptor = -1
        unlink(socketURL.path)
    }
}
