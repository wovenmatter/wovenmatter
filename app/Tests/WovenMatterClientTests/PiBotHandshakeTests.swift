// NWListener is macOS-only; Linux hosts build these tests without it.
#if canImport(Network)
import Foundation
import Network
import Testing
@testable import WovenMatterClient

/// What the Mac actually puts on the wire when it opens `/v1/bots/ws`. A Woven server's bots
/// proxy refuses any request with an `Origin` header (browser pages); remote/test/bots.test.mjs
/// replays these headers against it.
struct PiBotHandshakeTests {
    @Test func theBotsSocketHandshakeCarriesTheBearerAndNoOrigin() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let captured = AsyncStream<String>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                captured.continuation.yield(String(decoding: data ?? Data(), as: UTF8.self))
                connection.cancel()
            }
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var ports = ready.stream.makeAsyncIterator()
        let port = try #require(await ports.next())

        let client = PiBotClient(socketURL: URL(string: "http://127.0.0.1:\(port)/v1/bots/ws")!, bearer: "fixture-bearer") { _ in }
        await client.connect()
        defer { Task { await client.invalidate() } }
        var requests = captured.stream.makeAsyncIterator()
        let request = try #require(await requests.next())

        let lines = request.components(separatedBy: "\r\n")
        #expect(lines.first == "GET /v1/bots/ws HTTP/1.1")
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        #expect(headers["origin"] == nil)
        #expect(headers["authorization"] == "Bearer fixture-bearer")
        #expect(headers["upgrade"]?.lowercased() == "websocket")
        #expect(headers["cookie"] == nil)
    }
}
#endif
