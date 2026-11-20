import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#endif
@testable import WovenServerKit

/// A server that answers the upgrade and sends its first message in one
/// write, so both arrive at the client together.
@Test(.timeLimit(.minutes(1)))
func aMessageThatArrivesWithTheUpgradeReplyIsKept() async throws {
  let path = "/tmp/wvw-\(UUID().uuidString.prefix(8)).sock"
  #if canImport(Glibc)
  let listening = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
  let listening = socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  defer {
    close(listening)
    unlink(path)
  }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in Array(path.utf8).enumerated() { buffer[index] = byte }
  }
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  try #require(bound == 0 && listen(listening, 1) == 0)
  Thread {
    let fd = accept(listening, nil, nil)
    var request = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 { break }
      request.append(contentsOf: chunk[0..<count])
    }
    let key = String(decoding: request, as: UTF8.self).split(separator: "\r\n")
      .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
      .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
    let accepted = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    let reply = Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(accepted)\r\n\r\n").utf8) + [0x81, 5] + Array("hello".utf8)
    _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    // Held open until the client has read it.
    _ = read(fd, &chunk, chunk.count)
    close(fd)
  }.start()

  let transport = try await connectWebSocket(.unix(path: path))
  defer { transport.close() }
  let first = await withTaskGroup(of: String?.self) { group in
    group.addTask {
      do { for try await text in transport.incoming { return text } } catch {}
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(10))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
  #expect(first == "hello")
}
