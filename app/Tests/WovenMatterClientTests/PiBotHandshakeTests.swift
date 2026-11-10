import CryptoKit
import Foundation
import Network
import Testing
import WovenMatterCore
@testable import WovenMatterClient

/// What the Mac actually puts on the wire when it opens `/v1/bots/ws`. A Woven server's bots
/// proxy refuses any request with an `Origin` header (browser pages); remote/test/bots.test.mjs
/// replays these headers against it.
struct PiBotHandshakeTests {
    @Test func theBotsSocketHandshakeCarriesTheBearerAndNoOrigin() async throws {
        let headers = try await Self.handshake { port in
            PiBotClient(socketURL: URL(string: "http://127.0.0.1:\(port)/v1/bots/ws")!, bearer: "fixture-bearer") { _ in }
        }
        #expect(headers["origin"] == nil)
        #expect(headers["authorization"] == "Bearer fixture-bearer")
        #expect(headers["upgrade"]?.lowercased() == "websocket")
        #expect(headers["cookie"] == nil)
    }

    /// Another member's bots socket: the upgrade is signed for that member, with no
    /// bearer, and verifies there (the Mac companion and the Linux server check it).
    @Test func aSignedBotsSocketUpgradeVerifiesAtItsMemberOnly() async throws {
        let key = Curve25519.Signing.PrivateKey(), device = UUID().uuidString.lowercased(), machine = UUID().uuidString.lowercased()
        let signer = MemberRequestSigner(deviceID: device, key: key)
        let endpoint = BotSocketEndpoint.signed(URL(string: "http://127.0.0.1/v1/bots/ws")!, audience: machine)
        #expect(endpoint.isSigned && endpoint.bearer.isEmpty)
        let headers = try await Self.handshake { port in
            PiBotClient(socketURL: URL(string: "http://127.0.0.1:\(port)/v1/bots/ws")!, bearer: nil, authorize: { url in
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                return try signer.headers(method: "GET", target: components.percentEncodedPath, audience: machine)
            }) { _ in }
        }
        #expect(headers["authorization"] == nil && headers["origin"] == nil)
        let member = MemberKey(deviceID: device, kind: .mac, name: "Mac", publicKey: key.publicKey.rawRepresentation)
        let there = MemberRequestVerifier(audience: machine, lookup: { $0 == device ? member : nil })
        #expect(try await there.verify(method: "GET", target: "/v1/bots/ws", headers: headers, body: Data(), allowing: [.mac]) == member)
        let elsewhere = MemberRequestVerifier(audience: UUID().uuidString.lowercased(), lookup: { $0 == device ? member : nil })
        await #expect(throws: MemberRequestError.audience) {
            try await elsewhere.verify(method: "GET", target: "/v1/bots/ws", headers: headers, body: Data(), allowing: [.mac])
        }
    }

    /// The first upgrade request a client sends, as lowercased headers.
    private static func handshake(_ make: (UInt16) -> PiBotClient) async throws -> [String: String] {
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

        let client = make(port)
        await client.connect()
        defer { Task { await client.invalidate() } }
        var requests = captured.stream.makeAsyncIterator()
        let request = try #require(await requests.next())

        let lines = request.components(separatedBy: "\r\n")
        #expect(lines.first == "GET /v1/bots/ws HTTP/1.1")
        return Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
    }
}
