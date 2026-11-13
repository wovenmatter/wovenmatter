#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// The head has a fixed deadline; a body only has to keep moving, so a large
/// upload over a slow path completes and a stalled one is dropped.
@Suite("Socket server deadlines", .serialized)
struct LibrarySocketDeadlineTests {
  private static func server() throws -> (LibrarySocketHTTPServer, String, URL) {
    let directory = URL(fileURLWithPath: "/tmp").appending(path: "wmd-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var deadlines = LibraryHTTPParser.Deadlines()
    deadlines.header = 0.5; deadlines.bodyIdle = 0.6
    let server = LibrarySocketHTTPServer(deadlines: deadlines) { request in .init(body: Data("{\"bytes\":\(request.body.count)}".utf8)) }
    let path = directory.appending(path: "s.sock").path
    try server.start(.unix(path: path))
    return (server, path, directory)
  }

  /// Sends `chunks` with `gap` between them and returns the reply, or nil when the server closed first.
  private static func exchange(_ path: String, chunks: [Data], gap: TimeInterval) throws -> String? {
    let fd = socket(AF_UNIX, PortablePOSIX.streamSocket, 0)
    defer { close(fd) }
    var address = try #require(PortablePOSIX.unixAddress(path: path))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(connected == 0)
    _ = PortablePOSIX.disableBrokenPipeSignal(fd)
    for (index, chunk) in chunks.enumerated() {
      if index > 0 { Thread.sleep(forTimeInterval: gap) }
      let sent = chunk.withUnsafeBytes { send(fd, $0.baseAddress, chunk.count, 0) }
      if sent < 0 { return nil }
    }
    var reply = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count <= 0 { break }
      reply.append(contentsOf: buffer[0..<count])
    }
    return reply.isEmpty ? nil : String(decoding: reply, as: UTF8.self)
  }

  @Test func aSlowBodyCompletesWhileItKeepsMoving() throws {
    let (server, path, directory) = try Self.server()
    defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
    let body = Data(repeating: 0x20, count: 4_000)
    let head = Data("POST /v1/x HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    // Four body chunks 0.35 s apart: well past the 0.5 s head deadline in all.
    let parts = stride(from: 0, to: body.count, by: 1_000).map { body.subdata(in: $0..<min($0 + 1_000, body.count)) }
    let reply = try #require(try Self.exchange(path, chunks: [head] + parts, gap: 0.35))
    #expect(reply.hasPrefix("HTTP/1.1 200") && reply.contains("{\"bytes\":4000}"))
  }

  @Test func aStalledBodyOrHeadIsDropped() throws {
    let (server, path, directory) = try Self.server()
    defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
    let head = Data("POST /v1/x HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n".utf8)
    #expect(try Self.exchange(path, chunks: [head, Data("12345".utf8), Data("67890".utf8)], gap: 1.0) == nil)
    let partial = Data("POST /v1/x HTTP/1.1\r\nHost: local".utf8)
    #expect(try Self.exchange(path, chunks: [partial, Data("host\r\n\r\n".utf8)], gap: 0.8) == nil)
  }
}
