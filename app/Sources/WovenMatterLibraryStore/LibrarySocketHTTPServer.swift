#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import WovenMatterCore

/// POSIX sockets counterpart of `LibraryHTTPServer` for hosts without
/// Network.framework, and for Unix-domain sockets on every platform. It applies
/// the same parser, one request per connection, the same deadlines and the same
/// response framing. The Mac app keeps its NWListener server unchanged.
///
/// Each accepted connection is served by its own thread with blocking, polled
/// I/O; at most 32 connections are open at once, as with the Mac listener.
public final class LibrarySocketHTTPServer: @unchecked Sendable {
  public typealias Handler = LibraryHTTPResponseHandler
  public enum Endpoint: Sendable, Equatable {
    /// 127.0.0.1 only; port 0 selects a free port.
    case loopback(port: UInt16)
    /// A socket file created with 0600 permissions. Peers must run as this user.
    case unix(path: String)
  }

  private let handler: Handler
  private let streamIdleTimeout: TimeInterval
  private let deadlines: LibraryHTTPParser.Deadlines
  private let admitUnixPeer: (@Sendable (Int32?) -> Bool)?
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var stopped = false
  private var clients = 0
  private var socketPath: String?

  /// `admitUnixPeer` decides, from the connecting process ID the kernel
  /// reports, whether a Unix socket peer of this user may talk to the server.
  public init(streamIdleTimeout: TimeInterval = 180, deadlines: LibraryHTTPParser.Deadlines = .init(),
              admitUnixPeer: (@Sendable (Int32?) -> Bool)? = nil, handler: @escaping Handler) {
    precondition(streamIdleTimeout.isFinite && streamIdleTimeout > 0)
    self.handler = handler; self.streamIdleTimeout = streamIdleTimeout; self.deadlines = deadlines; self.admitUnixPeer = admitUnixPeer
    PortablePOSIX.ignoreBrokenPipes()
  }

  /// Returns the bound TCP port, or 0 for a Unix socket.
  @discardableResult
  public func start(_ endpoint: Endpoint) throws -> UInt16 {
    try lock.withLock {
      guard listener < 0, !stopped else {
        throw LibraryAPIError(code: "already_running", message: "The library listener is already running.")
      }
    }
    let fd: Int32
    var port: UInt16 = 0
    switch endpoint {
    case .loopback(let requested):
      fd = socket(AF_INET, PortablePOSIX.streamSocket, 0)
      guard fd >= 0 else { throw Self.posixError() }
      var one: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
      var address = sockaddr_in()
      #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      #endif
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = requested.bigEndian
      address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      guard bound == 0 else { let error = Self.posixError(); Darwin.close(fd); throw error }
      var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      port = UInt16(bigEndian: actual.sin_port)
    case .unix(let path):
      guard var address = PortablePOSIX.unixAddress(path: path) else {
        throw LibraryAPIError(code: "invalid_endpoint", message: "The socket path is too long.")
      }
      // Only replace a stale socket, never a regular file or directory.
      var info = stat()
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK else {
          throw LibraryAPIError(code: "invalid_endpoint", message: "The socket path is occupied by another file.")
        }
        unlink(path)
      }
      fd = socket(AF_UNIX, PortablePOSIX.streamSocket, 0)
      guard fd >= 0 else { throw Self.posixError() }
      let previous = umask(0o177)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      umask(previous)
      guard bound == 0, chmod(path, 0o600) == 0 else { let error = Self.posixError(); Darwin.close(fd); throw error }
      lock.withLock { socketPath = path }
    }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    guard listen(fd, 64) == 0 else { let error = Self.posixError(); Darwin.close(fd); throw error }
    let accepted = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      listener = fd; return true
    }
    guard accepted else { Darwin.close(fd); throw CancellationError() }
    let unix: Bool = { if case .unix = endpoint { return true }; return false }()
    let thread = Thread { [self] in acceptLoop(fd, unix: unix) }
    thread.name = "com.wovenmatter.library.socket"
    thread.start()
    return port
  }

  public func stop() {
    let (fd, path) = lock.withLock { () -> (Int32, String?) in
      stopped = true
      defer { listener = -1; socketPath = nil }
      return (listener, socketPath)
    }
    if fd >= 0 { shutdown(fd, PortablePOSIX.shutdownBoth); Darwin.close(fd) }
    if let path { unlink(path) }
  }

  private var isStopped: Bool { lock.withLock { stopped } }

  private func acceptLoop(_ fd: Int32, unix: Bool) {
    while !isStopped {
      var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&item, 1, 250)
      if ready <= 0 { continue }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      // The Unix socket is private to this user; the kernel names the peer.
      if unix, PortablePOSIX.peerUser(client) != getuid() || admitUnixPeer.map({ !$0(PortablePOSIX.peerProcess(client)) }) == true {
        Darwin.close(client); continue
      }
      let admitted = lock.withLock { () -> Bool in
        guard clients < 32, !stopped else { return false }
        clients += 1; return true
      }
      guard admitted, PortablePOSIX.disableBrokenPipeSignal(client) else { Darwin.close(client); continue }
      let connection = Thread { [self] in
        serve(client)
        Darwin.close(client)
        lock.withLock { clients -= 1 }
      }
      connection.name = "com.wovenmatter.library.connection"
      connection.start()
    }
  }

  private func serve(_ fd: Int32) {
    var parser = LibraryHTTPParser()
    let started = Date()
    let headerDeadline = started.addingTimeInterval(deadlines.header), bodyDeadline = started.addingTimeInterval(deadlines.body)
    var progress = started
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    let request: LibraryHTTPRequest
    do {
      while true {
        // A fixed deadline for the head; after it the body must keep moving.
        let deadline = parser.headersComplete ? min(bodyDeadline, progress.addingTimeInterval(deadlines.bodyIdle)) : headerDeadline
        guard try wait(fd, events: Int16(POLLIN), until: deadline) else { return }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
        if count == 0 { return }
        progress = Date()
        if let parsed = try parser.append(Data(buffer[0..<count])) { request = parsed; break }
      }
    } catch {
      _ = write(fd, Self.frame(.error("invalid_request", "Invalid or oversized library request.", status: 400)).head,
                deadline: Date().addingTimeInterval(15))
      return
    }
    let response = Self.wait { [handler] in await handler(request) }
    let framed = Self.frame(response)
    guard let producer = framed.stream else {
      // A large reply (a peer page) over a slow path keeps going while it moves.
      _ = write(fd, framed.head, deadline: Date().addingTimeInterval(deadlines.body), idle: deadlines.bodyIdle)
      return
    }
    stream(fd, head: framed.head, producer: producer)
  }

  private func stream(_ fd: Int32, head: Data, producer: @escaping LibraryHTTPResponse.Stream) {
    let activity = StreamActivity()
    let idle = streamIdleTimeout
    let writer = DispatchQueue(label: "com.wovenmatter.library.stream")
    @Sendable func emit(_ bytes: Data) async throws {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        writer.async { [self] in
          if write(fd, bytes, deadline: Date().addingTimeInterval(idle)) { activity.touch(); continuation.resume() }
          else { continuation.resume(throwing: CancellationError()) }
        }
      }
    }
    let finished = DispatchSemaphore(value: 0)
    let task = Task {
      defer { finished.signal() }
      do {
        try await emit(head)
        try await producer { bytes in
          guard !bytes.isEmpty else { return }
          for offset in stride(from: 0, to: bytes.count, by: 64 * 1_024) {
            let count = min(64 * 1_024, bytes.count - offset)
            let start = bytes.index(bytes.startIndex, offsetBy: offset)
            var chunk = Data((String(count, radix: 16) + "\r\n").utf8)
            chunk.append(bytes[start..<bytes.index(start, offsetBy: count)]); chunk.append(contentsOf: [13, 10])
            try await emit(chunk)
          }
        }
        try await emit(Data("0\r\n\r\n".utf8))
      } catch { /* An incomplete chunked response signals failure to the client. */ }
    }
    while finished.wait(timeout: .now() + 1) == .timedOut {
      // A closed peer or a silent producer ends the stream and cancels its producer.
      var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let peerClosed = poll(&item, 1, 0) > 0 && item.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
      if peerClosed || Date().timeIntervalSince(activity.last) > idle { task.cancel(); shutdown(fd, PortablePOSIX.shutdownBoth) }
    }
  }

  /// Runs an async handler from this connection's own thread. Only these
  /// dedicated threads block; Swift concurrency threads never wait here.
  private static func wait(_ body: @escaping @Sendable () async -> LibraryHTTPResponse) -> LibraryHTTPResponse {
    let box = ResponseBox()
    let done = DispatchSemaphore(value: 0)
    Task { box.value = await body(); done.signal() }
    done.wait()
    return box.value ?? .error("unavailable", "The request was not handled.", status: 503)
  }

  private func wait(_ fd: Int32, events: Int16, until deadline: Date) throws -> Bool {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0, !isStopped else { return false }
      var item = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&item, 1, Int32(min(remaining * 1_000, 250)))
      if result < 0 { if errno == EINTR { continue }; return false }
      if result == 0 { continue }
      if item.revents & events != 0 { return true }
      return false
    }
  }

  private func write(_ fd: Int32, _ data: Data, deadline: Date, idle: TimeInterval? = nil) -> Bool {
    var offset = 0, progress = Date()
    while offset < data.count {
      let limit = idle.map { min(deadline, progress.addingTimeInterval($0)) } ?? deadline
      guard (try? wait(fd, events: Int16(POLLOUT), until: limit)) == true else { return false }
      let written = data.withUnsafeBytes { bytes in
        #if canImport(Darwin)
        Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        #else
        send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
        #endif
      }
      if written < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
      offset += written; progress = Date()
    }
    return true
  }

  /// The same validation and header layout as the Mac listener.
  static func frame(_ response: LibraryHTTPResponse) -> (head: Data, stream: LibraryHTTPResponse.Stream?) {
    guard (100...599).contains(response.status), !response.contentType.isEmpty,
      response.contentType.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
      return frame(.error("invalid_response", "The server could not encode its response.", status: 500))
    }
    guard response.headers.allSatisfy({ name, value in
      !name.isEmpty && name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        && !["content-length", "transfer-encoding", "connection", "content-type"].contains(name.lowercased())
        && value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
    }) else { return frame(.error("invalid_response", "Invalid response headers.", status: 500)) }
    let extraHeaders = response.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
    let reason = response.status == 200 ? "OK" : response.status == 202 ? "Accepted" : "Request Error"
    let framing = response.stream == nil ? "Content-Length: \(response.body.count)" : "Transfer-Encoding: chunked"
    var wire = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n\(extraHeaders)\(framing)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
    if response.stream == nil { wire.append(response.body) }
    return (wire, response.stream)
  }

  private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

public typealias LibraryHTTPResponseHandler = @Sendable (LibraryHTTPRequest) async -> LibraryHTTPResponse

private final class ResponseBox: @unchecked Sendable { var value: LibraryHTTPResponse? }

private final class StreamActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var stamp = Date()
  var last: Date { lock.withLock { stamp } }
  func touch() { lock.withLock { stamp = Date() } }
}
