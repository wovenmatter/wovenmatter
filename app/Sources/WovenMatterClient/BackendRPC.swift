import Darwin
import Foundation

public struct BackendRPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let payload: Data
    public init(id: String = UUID().uuidString, method: String, payload: Data = Data()) {
        self.id = id; self.method = method; self.payload = payload
    }
}

public struct BackendRPCResponse: Codable, Sendable {
    public let id: String
    public let result: Data?
    public let error: String?
    public init(id: String, result: Data = Data()) { self.id = id; self.result = result; self.error = nil }
    public init(id: String, error: String) { self.id = id; self.result = nil; self.error = error }
}

public struct BackendRPCIdentity: Codable, Sendable {
    public let protocolVersion: Int
    public let processID: Int32
}

public enum BackendRPCError: Error, LocalizedError, Sendable {
    case unavailable, invalidEndpoint, unauthorized, invalidFrame, timedOut, remote(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The background service is unavailable."
        case .invalidEndpoint: "The background service endpoint is invalid or already in use."
        case .unauthorized: "The background service endpoint does not belong to this user."
        case .invalidFrame: "The background service sent an invalid response."
        case .timedOut: "The background service request timed out."
        case .remote(let message): message
        }
    }
}

/// One bounded request per connection. Filesystem permissions and kernel peer credentials
/// authenticate both ends; no bearer token is persisted or sent through this transport.
public struct BackendRPCClient: Sendable {
    public let socketURL: URL
    public init(socketURL: URL) { self.socketURL = socketURL }
    public func call(method: String, payload: Data = Data(), requestID: String = UUID().uuidString, timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try callSynchronously(method: method, payload: payload, requestID: requestID, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// For existing serial write-behind queues only; never call on the main or cooperative executor.
    public func callSynchronously(method: String, payload: Data = Data(), requestID: String = UUID().uuidString, timeout: TimeInterval = 30) throws -> Data {
            try BackendSocket.validateDirectory(socketURL.deletingLastPathComponent(), create: false)
            let fd = try BackendSocket.make()
            defer { Darwin.close(fd) }
            var address = try BackendSocket.address(socketURL)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if status != 0 && errno != EINPROGRESS { throw BackendRPCError.unavailable }
            let deadline = Date().addingTimeInterval(max(0.05, min(timeout, 30)))
            try BackendSocket.ready(fd, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                throw BackendRPCError.unavailable
            }
            try BackendSocket.authenticate(fd)
            let request = BackendRPCRequest(id: requestID, method: method, payload: payload)
            try BackendSocket.writeFrame(JSONEncoder().encode(request), fd: fd, deadline: deadline)
            let response = try JSONDecoder().decode(BackendRPCResponse.self, from: BackendSocket.readFrame(fd: fd, deadline: deadline))
            guard response.id == request.id else { throw BackendRPCError.invalidFrame }
            if let error = response.error { throw BackendRPCError.remote(error) }
            guard let result = response.result else { throw BackendRPCError.invalidFrame }
            return result
    }
    public func ping() async throws -> BackendRPCIdentity {
        try JSONDecoder().decode(BackendRPCIdentity.self, from: await call(method: "backend.ping"))
    }
}

public final class BackendRPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BackendRPCRequest) async -> BackendRPCResponse
    public let socketURL: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var generation = UUID()
    private let slots = DispatchSemaphore(value: 32)
    public init(socketURL: URL) { self.socketURL = socketURL }
    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == -1 else { return }
        try BackendSocket.validateDirectory(socketURL.deletingLastPathComponent(), create: true)
        let fd = try BackendSocket.make()
        var succeeded = false
        defer { if !succeeded { Darwin.close(fd) } }
        var address = try BackendSocket.address(socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw BackendRPCError.invalidEndpoint }
        guard chmod(socketURL.path, 0o600) == 0, listen(fd, 32) == 0 else {
            unlink(socketURL.path); throw BackendRPCError.unavailable
        }
        descriptor = fd; succeeded = true
        let startedGeneration = UUID(); generation = startedGeneration
        DispatchQueue(label: "wovenmatter.backend.accept").async { [weak self] in
            while let self, self.isRunning(fd, generation: startedGeneration) {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pollDescriptor, 1, 250) > 0 else { continue }
                // Hold the lifecycle lock across accept so stop cannot recycle the descriptor.
                self.lock.lock()
                let client = self.descriptor == fd && self.generation == startedGeneration ? accept(fd, nil, nil) : -1
                self.lock.unlock()
                guard client >= 0 else { continue }
                guard self.slots.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        try BackendSocket.configure(client)
                        try BackendSocket.authenticate(client)
                        let deadline = Date().addingTimeInterval(30)
                        let request = try JSONDecoder().decode(BackendRPCRequest.self, from: BackendSocket.readFrame(fd: client, deadline: deadline))
                        Task {
                            let response: BackendRPCResponse
                            if request.method == "backend.ping" {
                                let identity = BackendRPCIdentity(protocolVersion: 1, processID: getpid())
                                response = BackendRPCResponse(id: request.id, result: (try? JSONEncoder().encode(identity)) ?? Data())
                            } else {
                                response = await handler(request)
                            }
                            DispatchQueue.global(qos: .userInitiated).async {
                                defer { Darwin.close(client); self.slots.signal() }
                                // Fail closed; never log payloads or credentials.
                                try? BackendSocket.writeFrame(JSONEncoder().encode(response), fd: client, deadline: deadline)
                            }
                        }
                    } catch { Darwin.close(client); self.slots.signal() }
                }
            }
        }
    }
    private func isRunning(_ fd: Int32, generation expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return descriptor == fd && generation == expected
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1
        unlink(socketURL.path)
    }
}

private enum BackendSocket {
    static let maximumFrame = 8 * 1024 * 1024
    static func validateDirectory(_ url: URL, create: Bool) throws {
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BackendRPCError.unauthorized }
    }
    static func address(_ url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BackendRPCError.invalidEndpoint }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }
    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendRPCError.unavailable }
        do { try configure(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw BackendRPCError.unavailable }
    }
    static func authenticate(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw BackendRPCError.unauthorized }
    }
    static func ready(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BackendRPCError.timedOut }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw BackendRPCError.timedOut }
            guard item.revents & events != 0 else { throw BackendRPCError.unavailable }
            return
        }
    }
    static func readFrame(fd: Int32, deadline: Date) throws -> Data {
        let header = try read(4, fd: fd, deadline: deadline)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumFrame else { throw BackendRPCError.invalidFrame }
        return try read(length, fd: fd, deadline: deadline)
    }
    static func read(_ count: Int, fd: Int32, deadline: Date) throws -> Data {
        var data = Data(count: count); var offset = 0
        while offset < count {
            try ready(fd, events: Int16(POLLIN), deadline: deadline)
            let amount = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if amount < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard amount > 0 else { throw BackendRPCError.unavailable }
            offset += amount
        }
        return data
    }
    static func writeFrame(_ data: Data, fd: Int32, deadline: Date) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw BackendRPCError.invalidFrame }
        var size = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(data)
        var offset = 0
        while offset < frame.count {
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            let amount = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if amount < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard amount > 0 else { throw BackendRPCError.unavailable }
            offset += amount
        }
    }
}
