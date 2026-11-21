import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One HTTP/1.1 request over a Unix socket, for the Docker Engine API and the
/// VM helper's control API. Blocking: call it off the cooperative pool
/// (`UnixHTTP.request`).
enum UnixHTTP {
  struct Failure: Error, CustomStringConvertible {
    var description: String
  }

  /// Sends one request and reads the reply to the end (`Connection: close`).
  static func request(socket path: String, method: String = "GET", path target: String, body: Data? = nil,
                      timeout: Int = 30) async throws -> (status: Int, body: Data) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try exchange(path, method, target, body ?? Data(), timeout) })
      }
    }
  }

  /// Whether a Docker Engine answers on `socket`.
  static func dockerAnswers(_ socket: String) async -> Bool {
    guard let reply = try? await request(socket: socket, path: "/_ping", timeout: 5) else { return false }
    return reply.status == 200
  }

  private static func exchange(_ socketPath: String, _ method: String, _ target: String, _ body: Data,
                               _ timeout: Int) throws -> (status: Int, body: Data) {
    #if canImport(Glibc)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw Failure(description: "No socket is available.") }
    defer { close(fd) }
    #if canImport(Darwin)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var interval = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw Failure(description: "The socket path \(socketPath) is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw Failure(description: "Nothing answers on \(socketPath).") }
    var request = Data("\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.count)\r\n".utf8)
    if !body.isEmpty { request += Data("Content-Type: application/json\r\n".utf8) }
    request += Data("\r\n".utf8) + body
    try request.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        #if canImport(Glibc)
        let written = send(fd, buffer.baseAddress! + offset, buffer.count - offset, Int32(MSG_NOSIGNAL))
        #else
        let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        #endif
        guard written > 0 else { throw Failure(description: "\(socketPath) closed the connection.") }
        offset += written
      }
    }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(fd, &chunk, chunk.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { break }
      reply.append(chunk, count: count)
    }
    guard let end = reply.range(of: Data("\r\n\r\n".utf8)),
          let head = String(data: reply[..<end.lowerBound], encoding: .utf8) else {
      throw Failure(description: "\(socketPath) closed the connection without a reply.")
    }
    let parts = head.prefix { $0 != "\r" }.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else {
      throw Failure(description: "\(socketPath) sent a malformed reply.")
    }
    return (status, Data(reply[end.upperBound...]))
  }
}
