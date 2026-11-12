import Darwin
import Foundation

enum Sockets {
    static func posixError(_ what: String) -> Error {
        WovenVMError.failed("\(what): \(String(cString: strerror(errno)))")
    }

    /// A 0600 Unix listener. The parent directory is 0700 as well, so only
    /// this user can connect; peers are checked again on accept.
    static func listenUnix(at url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        unlink(url.path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw WovenVMError.invalid("The socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let previous = umask(0o177)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard result == 0, chmod(url.path, 0o600) == 0, listen(fd, 128) == 0 else {
            let error = posixError("bind \(url.lastPathComponent)")
            close(fd)
            throw error
        }
        return fd
    }

    /// Binds 127.0.0.1 only: previews are published to the tailnet by Woven's
    /// own proxy, never by the VM.
    static func listenLoopback(port: Int) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            let error = posixError("bind 127.0.0.1:\(port)")
            close(fd)
            throw error
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: actual.sin_port)))
    }

    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads one newline-terminated line, byte by byte so nothing after it is
    /// consumed (the bytes that follow belong to the spliced stream).
    static func readLine(_ fd: Int32, limit: Int = 4096) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < limit {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    /// Copies both directions until each one ends on its own. End of stream in
    /// one direction becomes shutdown(SHUT_WR) on the other socket, which keeps
    /// HTTP hijack/upgrade streams (docker exec with stdin closed) delivering
    /// output until the far side finishes. Both sockets close when both
    /// directions are done.
    static func splice(_ first: Int32, _ second: Int32) {
        setBlocking(first)
        setBlocking(second)
        let remaining = Remaining(first: first, second: second)
        for (source, destination) in [(first, second), (second, first)] {
            let thread = Thread {
                pump(from: source, to: destination)
                remaining.finishOne()
            }
            thread.stackSize = 256 << 10
            thread.start()
        }
    }

    private final class Remaining: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 2
        private let first: Int32, second: Int32
        init(first: Int32, second: Int32) {
            self.first = first
            self.second = second
        }
        func finishOne() {
            lock.lock()
            count -= 1
            let last = count == 0
            lock.unlock()
            if last {
                close(first)
                close(second)
            }
        }
    }

    private static func pump(from source: Int32, to destination: Int32) {
        let size = 128 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var failed = false
        loop: while true {
            let count = read(source, buffer, size)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 {
                failed = count < 0
                break
            }
            var offset = 0
            while offset < count {
                let written = write(destination, buffer + offset, count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 {
                    failed = true
                    break loop
                }
                offset += written
            }
        }
        let readErrno = errno
        let result = shutdown(destination, SHUT_WR)
        let shutdownErrno = errno
        // The destination is gone: stop reading from a peer whose output can
        // no longer be delivered, which also ends the opposite direction.
        if failed { shutdown(source, SHUT_RD) }
        if trace {
            FileHandle.standardError.write(Data("TRACE pump \(source)->\(destination) failed=\(failed) errno=\(readErrno) shutdown=\(result) errno=\(shutdownErrno)\n".utf8))
        }
    }

    /// WOVEN_VM_TRACE=1 (when running the helper by hand) logs how each
    /// direction of every bridged stream ended, for half-close diagnosis.
    static let trace = ProcessInfo.processInfo.environment["WOVEN_VM_TRACE"] == "1"
}

/// Accepts on a listening descriptor without blocking a thread, so a forward
/// can be cancelled at any time.
final class Listener: @unchecked Sendable {
    let fd: Int32
    private let source: any DispatchSourceRead

    init(fd: Int32, queue: DispatchQueue, accept handler: @escaping @Sendable (Int32) -> Void) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                handler(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func cancel() { source.cancel() }
}
