import Foundation
import Network
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HermesGatewayRPCTests {
    @Test func stopDuringResponseJournalPreventsNativeWrite() async throws {
        let server = try HermesWireFixture()
        let port = try await server.start()
        let fence = AgentDispatchFence()
        let client = HermesGatewayRPC(connection: HermesGatewayConnection(home: "/tmp/hermes-wire", port: port, token: "fixture", pid: 1),
            historyRecorder: { direction, data in
                if direction == "out", String(decoding: data, as: UTF8.self).contains("blocked-approval") {
                    await Task.yield()
                    fence.cancel()
                }
            })
        do {
            try await client.connect()
            await #expect(throws: CancellationError.self) {
                try await client.respond(id: "blocked-approval", result: ["choice": "once"], dispatchFence: fence)
            }
            #expect(!fence.hasDispatched)
            // Flush a later request through the peer, proving no earlier blocked
            // response was sent, while a normal denial still uses native schema.
            try await client.respond(id: "denied", result: ["choice": "deny"])
            _ = try await client.call("ping")
            #expect(await !server.receivedIDs.contains("blocked-approval"))
            #expect(await server.receivedIDs.contains("denied"))
        } catch {
            await client.disconnect(); await server.stop(); throw error
        }
        await client.disconnect(); await server.stop()
    }

    @Test func routesServerRequestsAndRequiresAFreshReplayEpochOnReconnect() async throws {
        let server = try HermesWireFixture()
        let port = try await server.start()
        let capture = HermesWireCapture()
        let client = HermesGatewayRPC(connection: HermesGatewayConnection(home: "/tmp/hermes-wire", port: port, token: "private-fixture-token", pid: 1),
            historyRecorder: { capture.append($0, $1) })
        await client.setHandlers(event: nil, request: { frame in
            try? await client.respond(id: frame["id"].text, result: ["value": "fixture-answer"])
        })
        do {
            try await client.connect()
            #expect(await client.epoch == "wire-epoch")
            let answer = try await client.call("fixture.ask")
            #expect(answer == ["value": "fixture-answer"])
            let configuration: HermesValue = ["command": "encoded-private-cli-binding"]
            let configured = try await client.callConfiguration("shell.exec", configuration)
            #expect(configured == configuration)
            let ordinary = try await client.call("shell.exec", ["command": "ordinary-native-operation"])
            #expect(ordinary["command"].text == "ordinary-native-operation")
            let captured = capture.values
            #expect(!captured.contains { $0.1.contains("encoded-private-cli-binding") })
            #expect(captured.contains { $0.1.contains("ordinary-native-operation") })
            #expect(captured.contains { $0.0 == "in" && $0.1.contains("srq-fixture") })
            // The peer receives the secret reply, but its credential value
            // must be absent from retained transport observations.
            #expect(captured.contains { $0.0 == "out" && $0.1.contains("srq-fixture") })
            #expect(!captured.contains { $0.0 == "out" && $0.1.contains("fixture-answer") })
            #expect(!captured.contains { $0.1.contains("private-fixture-token") })
            await client.disconnect()
            // A server missing gateway.ready must not reuse a previous socket's epoch.
            await #expect(throws: (any Error).self) { try await client.connect() }
            #expect(await !client.isConnected)
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

private final class HermesWireCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String)] = []
    var values: [(String, String)] { lock.withLock { entries } }
    func append(_ direction: String, _ data: Data) {
        lock.withLock { entries.append((direction, String(decoding: data, as: UTF8.self))) }
    }
}

/// A loopback peer implementing only the JSON-RPC frames under test; no Hermes
/// executable, user profile, or provider service is involved.
private actor HermesWireFixture {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    var receivedIDs: [String] = []
    private var requestID: HermesValue = .null
    private let queue = DispatchQueue(label: "hermes-wire-fixture")

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: Int(listener.port!.rawValue))
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        let advertiseEpoch = connections.count == 1
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.ready(connection, advertiseEpoch: advertiseEpoch) } }
        }
        connection.start(queue: queue)
    }

    private func ready(_ connection: NWConnection, advertiseEpoch: Bool) async {
        if advertiseEpoch {
            await send(["jsonrpc": "2.0", "method": "event", "params": ["type": "gateway.ready", "payload": ["replay_epoch": "wire-epoch"]]], to: connection)
        }
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data, let frame = try? HermesValue.decode(data) else { return }
            Task { await self?.handle(frame, connection: connection) }
        }
    }

    private func handle(_ frame: HermesValue, connection: NWConnection) async {
        if let id = frame["id"].string { receivedIDs.append(id) }
        let result: HermesValue
        switch frame["method"].text {
        case "ping": result = ["pong": .bool(true)]
        case "config.get": result = ["home": "/tmp/hermes-wire"]
        case "shell.exec": result = frame["params"]
        case "fixture.ask":
            requestID = frame["id"]
            await send(["jsonrpc": "2.0", "id": "srq-fixture", "method": "secret", "params": ["session_id": "live", "prompt": "Fixture"]], to: connection)
            receive(connection)
            return
        default:
            if frame["id"].text == "srq-fixture" {
                await send(["jsonrpc": "2.0", "id": requestID, "result": frame["result"]], to: connection)
            }
            receive(connection)
            return
        }
        await send(["jsonrpc": "2.0", "id": frame["id"], "result": result], to: connection)
        receive(connection)
    }

    private func send(_ frame: HermesValue, to connection: NWConnection) async {
        let context = NWConnection.ContentContext(identifier: "json", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        let data = try! JSONEncoder().encode(frame)
        await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func stop() {
        for connection in connections { connection.cancel() }
        listener.cancel()
    }
}
