import Darwin
import Foundation
import WovenMatterCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func waitForOpen() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !lock.withLock({ opened }) {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "handler did not receive request")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}

private func address(_ path: String) -> sockaddr_un {
    var result = sockaddr_un()
    result.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString).map(UInt8.init(bitPattern:))
    precondition(bytes.count <= MemoryLayout.size(ofValue: result.sun_path))
    withUnsafeMutableBytes(of: &result.sun_path) { $0.copyBytes(from: bytes) }
    return result
}

private func rawSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TestFailure("socket: \(errno)") }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // Only test helpers suppress their own writes. Production sockets must configure themselves.
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    return descriptor
}

private func connectRaw(_ url: URL) throws -> Int32 {
    let descriptor = try rawSocket()
    var addr = address(url.path)
    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 { close(descriptor); throw TestFailure("connect: \(errno)") }
    return descriptor
}

private func sendRaw(_ data: Data, _ descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { throw TestFailure("test write: \(errno)") }
            offset += count
        }
    }
}

private func receiveRaw(_ descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count == 0 { return data }
        guard count > 0 else { throw TestFailure("test read: \(errno)") }
        data.append(contentsOf: buffer.prefix(count))
    }
}

private func closedPromptly(_ descriptor: Int32) throws {
    var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    try require(poll(&state, 1, 1_000) > 0, "peer was not closed promptly")
    var byte: UInt8 = 0
    let count = read(descriptor, &byte, 1)
    try require(count == 0 || (count < 0 && errno == ECONNRESET), "expected closed peer")
}

private func socketURL() -> URL {
    URL(fileURLWithPath: "/private/tmp/wmn-\(UUID().uuidString).sock")
}

private let readRequest = NoteEditingRequest(command: .read, noteID: "note")

@main
struct WovenNoteSocketTests {
    static func main() async throws {
        // A missing SO_NOSIGPIPE in either production writer must fail this process.
        signal(SIGPIPE, SIG_DFL)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("note socket regression timed out\n".utf8))
            exit(70)
        }
        try roundTrip()
        try idleDeadlineAndRecovery()
        try await trickleDeadline()
        try await connectionLimitAndDisconnect()
        try await slowReaderDeadline()
        try stopAndRestart()
        try cliDisconnectedPeer()
        try cliResponseDeadline()
        print("8 native note socket behavior tests passed")
    }

    static func roundTrip() throws {
        let url = socketURL()
        let service = WovenNoteService(socketURL: url) { request in
            NoteEditingResponse(success: true, noteID: request.noteID, title: "Linked note")
        }
        try service.start()
        defer { try? service.stop() }
        let response = try WovenNoteCommandLine.send(readRequest, socketPath: url.path)
        try require(response.success && response.noteID == "note" && response.title == "Linked note", "round-trip mismatch")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "socket permissions must be private")
    }

    static func idleDeadlineAndRecovery() throws {
        let url = socketURL()
        let service = WovenNoteService(socketURL: url, ioTimeout: 0.2) { request in
            NoteEditingResponse(success: true, noteID: request.noteID)
        }
        try service.start()
        defer { try? service.stop() }
        let idle = try connectRaw(url)
        defer { close(idle) }
        let start = ProcessInfo.processInfo.systemUptime
        let response = try JSONDecoder().decode(NoteEditingResponse.self, from: receiveRaw(idle))
        try require(!response.success && response.error?.contains("timed out") == true, "idle connection was not timed out")
        try require(ProcessInfo.processInfo.systemUptime - start < 1.5, "idle timeout was not bounded")
        let recovered = try WovenNoteCommandLine.send(readRequest, socketPath: url.path)
        try require(recovered.success, "service did not recover after timeout")
    }

    static func trickleDeadline() async throws {
        let url = socketURL()
        let service = WovenNoteService(socketURL: url, ioTimeout: 0.25) { request in
            NoteEditingResponse(success: true, noteID: request.noteID)
        }
        try service.start()
        defer { try? service.stop() }
        let client = try connectRaw(url)
        defer { close(client) }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            try? sendRaw(Data(" ".utf8), client)
            try await Task.sleep(for: .milliseconds(75))
        }
        let response = try JSONDecoder().decode(NoteEditingResponse.self, from: receiveRaw(client))
        try require(response.error?.contains("timed out") == true, "trickle traffic reset the request deadline")
        try require(ProcessInfo.processInfo.systemUptime - start < 1.5, "trickle deadline was not bounded")
    }

    static func connectionLimitAndDisconnect() async throws {
        let url = socketURL()
        let entered = Gate()
        let release = Gate()
        let service = WovenNoteService(socketURL: url, maximumConnections: 1) { request in
            if request.noteID == "blocked" {
                entered.open()
                await release.wait()
            }
            return NoteEditingResponse(success: true, noteID: request.noteID, title: String(repeating: "x", count: 200_000))
        }
        try service.start()
        defer { release.open(); try? service.stop() }
        let client = try connectRaw(url)
        try sendRaw(JSONEncoder().encode(NoteEditingRequest(command: .read, noteID: "blocked")), client)
        shutdown(client, SHUT_WR)
        try await entered.waitForOpen()
        let excess = try connectRaw(url)
        defer { close(excess) }
        try closedPromptly(excess)
        close(client)
        release.open() // The server writes to a peer that disconnected after submitting its request.
        try await requireRecovery(url)
    }

    static func requireRecovery(_ url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let response = try? WovenNoteCommandLine.send(readRequest, socketPath: url.path, timeout: 0.2), response.success {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure("service did not reclaim connection capacity")
    }

    static func slowReaderDeadline() async throws {
        let url = socketURL()
        let entered = Gate()
        let service = WovenNoteService(socketURL: url, maximumConnections: 1, ioTimeout: 0.2) { request in
            if request.noteID == "slow" { entered.open() }
            return NoteEditingResponse(success: true, noteID: request.noteID,
                title: request.noteID == "slow" ? String(repeating: "x", count: 2_000_000) : "recovered")
        }
        try service.start()
        defer { try? service.stop() }
        let slow = try connectRaw(url)
        defer { close(slow) }
        try sendRaw(JSONEncoder().encode(NoteEditingRequest(command: .read, noteID: "slow")), slow)
        shutdown(slow, SHUT_WR)
        try await entered.waitForOpen()
        // Never read the large response: a stalled writer must also release the sole slot.
        try await requireRecovery(url)
    }

    static func stopAndRestart() throws {
        let url = socketURL()
        let service = WovenNoteService(socketURL: url) { request in
            NoteEditingResponse(success: true, noteID: request.noteID)
        }
        defer { try? service.stop() }
        for _ in 0..<8 {
            try service.start()
            let idle = try connectRaw(url)
            // A completed request proves that the serial accept queue has accepted the earlier idle client.
            _ = try WovenNoteCommandLine.send(readRequest, socketPath: url.path)
            try service.stop()
            try closedPromptly(idle)
            close(idle)
            try require(!FileManager.default.fileExists(atPath: url.path), "stop left socket path behind")
        }
        try service.start()
        let response = try WovenNoteCommandLine.send(readRequest, socketPath: url.path)
        try require(response.success, "restart did not restore service")
    }

    static func fakePeer(_ operation: @escaping @Sendable (Int32) -> Void, client: (URL) throws -> Void) throws {
        let url = socketURL()
        let listener = try rawSocket()
        defer { close(listener); try? FileManager.default.removeItem(at: url) }
        var addr = address(url.path)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try require(result == 0 && listen(listener, 1) == 0, "fake peer failed to listen")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            var state = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&state, 1, 2_000) > 0 else { return }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            operation(peer)
        }
        defer { _ = done.wait(timeout: .now() + 3) }
        try client(url)
    }

    static func cliDisconnectedPeer() throws {
        try fakePeer({ peer in
            var byte: UInt8 = 0
            _ = read(peer, &byte, 1)
        }) { url in
            let request = NoteEditingRequest(command: .apply, noteID: "note", operations: [.setTitle(String(repeating: "x", count: 2_000_000))])
            var failed = false
            do { _ = try WovenNoteCommandLine.send(request, socketPath: url.path, timeout: 0.5) }
            catch { failed = true }
            try require(failed, "CLI accepted a disconnected peer")
        }
    }

    static func cliResponseDeadline() throws {
        try fakePeer({ peer in
            _ = try? receiveRaw(peer)
            Thread.sleep(forTimeInterval: 0.5)
        }) { url in
            let start = ProcessInfo.processInfo.systemUptime
            var failure: String?
            do { _ = try WovenNoteCommandLine.send(readRequest, socketPath: url.path, timeout: 0.15) }
            catch { failure = error.localizedDescription }
            try require(failure?.contains("timed out") == true, "CLI did not time out waiting for response")
            try require(ProcessInfo.processInfo.systemUptime - start < 1, "CLI response wait was not bounded")
        }
    }
}
