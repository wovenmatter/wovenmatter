import Foundation
import Network
import Testing
@testable import WovenMatterClient

/// The Mac's end of the relay against the real script, through the real launcher, under
/// the shells a remote login can have. Only SSH itself is left out.
@Suite(.serialized)
struct PiBotRelayTests {
    private static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private static var relaySource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appending(path: "scripts/pi-bot-relay.mjs"), encoding: .utf8)
        }
    }

    private final class Server: @unchecked Sendable {
        let listener: NWListener
        let port: Int
        init(respond: @escaping @Sendable (Data) -> Data) async throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                @Sendable func loop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, _ in
                        if let data, !data.isEmpty { connection.send(content: respond(data), completion: .idempotent) }
                        if complete { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) } else { loop() }
                    }
                }
                loop()
            }
            let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
            let owner = listener
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = owner.port { continuation.yield(Int(port.rawValue)) }
            }
            listener.start(queue: .global())
            port = await stream.first { _ in true } ?? 0
        }
        deinit { listener.cancel() }
    }

    private static func roundTrip(port: Int, send: Data, expecting count: Int) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        connection.send(content: send, completion: .idempotent)
        var collected = Data()
        while collected.count < count {
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if let error { continuation.resume(throwing: error) }
                    else if complete { continuation.resume(throwing: PiBotHostError.command("closed early")) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            collected.append(next)
        }
        return collected
    }

    private static func wait(_ relay: PiBotRelay) async throws -> PiBotRelay.Hello {
        for _ in 0..<200 {
            if let hello = relay.hello { return hello }
            #expect(relay.isRunning)
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PiBotHostError.command("no hello")
    }

    @Test(.enabled(if: node != nil), arguments: ["/bin/zsh", "/bin/bash"])
    func bothDirectionsWorkThroughTheLauncherUnderTheLoginShell(shell: String) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pi-bot-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let piBot = try await Server { Data("pi-bot:".utf8) + $0 }
        let mcp = try await Server { Data("mcp:".utf8) + $0 }
        let localPort = try #require(PiBotLoopback.freePort())
        let forward = PiBotTunnel.Forward(localPort: localPort, remotePort: piBot.port, mcpLocalPort: mcp.port)
        let command = "PATH=\(URL(fileURLWithPath: Self.node!).deletingLastPathComponent().path):$PATH HOME=\(RemoteWorkspaceExecTarget.quote(home.path)) "
            + PiBotTunnel.remoteCommand(instance: "fixture", relaySource: try Self.relaySource, forward: forward)
        let relay = PiBotRelay(executable: URL(fileURLWithPath: shell), arguments: ["-c", command], errorLog: nil,
                               localPort: localPort, reverseTargetPort: mcp.port)
        try relay.start()
        defer { relay.stop() }
        let hello = try await Self.wait(relay)
        let reverse = try #require(hello.reversePort)
        // The Mac's client reaches Pi Bot on the device.
        let toPiBot = try await Self.roundTrip(port: localPort, send: Data("hello".utf8), expecting: 12)
        #expect(String(decoding: toPiBot, as: UTF8.self) == "pi-bot:hello")
        // Pi Bot on the device reaches this Mac's MCP endpoint.
        let toMCP = try await Self.roundTrip(port: reverse, send: Data("tools".utf8), expecting: 9)
        #expect(String(decoding: toMCP, as: UTF8.self) == "mcp:tools")
    }

    @Test(.enabled(if: node != nil))
    func manyStreamsAndALargeTransferStaySeparateAndIntact() async throws {
        let piBot = try await Server { $0 }
        let localPort = try #require(PiBotLoopback.freePort())
        let relay = PiBotRelay(executable: URL(fileURLWithPath: Self.node!),
            arguments: ["--input-type=module", "-e", try Self.relaySource, "--", String(piBot.port), "none"],
            errorLog: nil, localPort: localPort, reverseTargetPort: nil)
        try relay.start()
        defer { relay.stop() }
        _ = try await Self.wait(relay)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let body = Data("stream-\(index)-".utf8) + Data(repeating: UInt8(index), count: 200_000)
                    let echoed = try await Self.roundTrip(port: localPort, send: body, expecting: body.count)
                    #expect(echoed == body)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func aChildThatExitsEndsTheRelay() async throws {
        let localPort = try #require(PiBotLoopback.freePort())
        let relay = PiBotRelay(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], errorLog: nil, localPort: localPort, reverseTargetPort: nil)
        try relay.start()
        for _ in 0..<100 where relay.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!relay.isRunning)
        #expect(relay.hello == nil)
    }
}
