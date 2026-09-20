import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct GatewaySessionPermissionTests {
    @Test func openClawPatchesNativePolicyAndCanRestoreInheritance() throws {
        let full = try OpenClawSessionPermissions.patchParameters(key: "agent:fixture:chat", preferences: .init(permissionMode: "full"))
        #expect(full == .object(["key": .string("agent:fixture:chat"), "permissionMode": .string("full")]))
        let restored = try OpenClawSessionPermissions.patchParameters(key: "chat", preferences: .init(permissionMode: "default"))
        #expect(restored.objectValue?["permissionMode"] == .null)
        let modelOnly = try OpenClawSessionPermissions.patchParameters(key: "chat", preferences: .init(model: "fixture/model"))
        #expect(modelOnly.objectValue?["permissionMode"] == nil)
        #expect(throws: (any Error).self) {
            try OpenClawSessionPermissions.patchParameters(key: "chat", preferences: .init(permissionMode: "autoapprove"))
        }
    }

    @Test func openClawRejectsUnconfirmedOrStillPendingDowngrade() throws {
        let confirmed: GatewayJSONValue = .object(["session": .object(["permissionMode": .string("read-only")])])
        try OpenClawSessionPermissions.confirm("read-only", description: confirmed)
        #expect(OpenClawGatewayClient.sessionPreferences(from: confirmed).permissionMode == "read-only")
        try OpenClawSessionPermissions.confirm("default", description: .object(["session": .object([:])]))
        for row: GatewayJSONValue in [.null, .object(["permissionMode": .string("full")]),
            .object(["permissionMode": .string("read-only"), "permissionModePending": .bool(true)])] {
            #expect(throws: (any Error).self) {
                try OpenClawSessionPermissions.confirm("read-only", description: .object(["session": row]))
            }
        }
    }

    @Test func hermesReportsNativeInheritedModesWithoutInventingDowngrades() {
        let smart = HermesSessionPermissions.configuration(info: ["yolo": .bool(false), "approval_mode": "smart"], inheritedMode: nil)
        #expect(smart.permission == "default")
        #expect(smart.permissionOptionMetadata["default"]?.name == "Smart approvals")
        let off = HermesSessionPermissions.configuration(info: ["yolo": .bool(true), "approval_mode": "off"], inheritedMode: nil)
        #expect(off.permission == "full")
        #expect(off.permissionOptions == ["full"])
        let preparing = HermesSessionPermissions.configuration(info: [:], inheritedMode: "manual")
        #expect(preparing.permission == nil)
    }

    @Test func hermesFullThenInheritedUsesSessionFlagAndAuthoritativeRead() async throws {
        let transport = PermissionHermesTransport()
        let client = makeHermes(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        #expect(try await client.setSessionPermission("full").permission == "full")
        #expect(try await client.setSessionPermission("default").permission == "default")
        let writes = await transport.calls.filter { $0.0 == "config.set" }
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0.1["key"] == "yolo" && $0.1["scope"] == "session" && $0.1["session_id"] == "live" })
        #expect(writes.map { $0.1["value"] } == ["1", "0"])
        #expect(await transport.calls.filter { $0.0 == "session.activate" }.count == 3)
        await client.shutdown()
    }

    @Test func hermesRestoresOnlyAnExplicitChoiceWhenTheSameSessionRecovers() async throws {
        let transport = PermissionHermesTransport()
        let client = makeHermes(transport)
        let created = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        _ = try await client.setSessionPermission("full")
        await transport.resetSessionOverride()
        let resumed = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: created.sessionID, title: nil, systemPrompt: nil)
        #expect(resumed.configuration.permission == "full")
        #expect(await transport.calls.filter { $0.0 == "config.set" }.count == 2)
        await client.shutdown()
    }

    @Test func hermesCannotClaimLowerAccessWhenProcessPolicyKeepsFull() async throws {
        let transport = PermissionHermesTransport(processFull: true)
        let client = makeHermes(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        await #expect(throws: (any Error).self) { try await client.setSessionPermission("default") }
        let configuration = await client.sessionConfiguration()
        #expect(configuration.permission == "full")
        #expect(configuration.permissionOptions == ["full"])
        await client.shutdown()
    }

    @Test func hermesRejectsWriteAcknowledgmentWithoutEffectiveState() async throws {
        let transport = PermissionHermesTransport(omitEffectiveState: true)
        let client = makeHermes(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        await #expect(throws: (any Error).self) { try await client.setSessionPermission("full") }
        #expect(await client.sessionConfiguration().permission == nil)
        await client.shutdown()
    }

    private func makeHermes(_ transport: PermissionHermesTransport) -> HermesGatewayClient {
        .init(launch: .init(runtimeKind: .hermes, executableURL: URL(fileURLWithPath: "/fixture/never-run"), arguments: [], environment: [:]),
            transport: transport, home: "/tmp/hermes-permission-fixture")
    }
}

private actor PermissionHermesTransport: HermesGatewayTransport {
    var epoch: String? = "fixture"
    var isConnected = false
    var calls: [(String, HermesValue)] = []
    private var full = false
    private let processFull: Bool
    private let omitEffectiveState: Bool
    init(processFull: Bool = false, omitEffectiveState: Bool = false) {
        self.processFull = processFull; self.omitEffectiveState = omitEffectiveState
    }
    func resetSessionOverride() { full = false }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false }
    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) {}
    func respond(id: String, result: HermesValue) {}
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        calls.append((method, params))
        switch method {
        case "session.create", "session.resume", "session.activate":
            let info: HermesValue = omitEffectiveState ? [:] : ["approval_mode": "manual", "yolo": .bool(full || processFull)]
            return ["session_id": "live", "stored_session_id": "stored", "info": info]
        case "config.get": return ["value": params["key"] == "approvals.mode" ? "manual" : "high"]
        case "config.set":
            guard params["key"] == "yolo", params["scope"] == "session", params["session_id"] == "live" else {
                throw HermesGatewayError.message("Unexpected configuration mutation")
            }
            full = params["value"] == "1"
            return ["scope": "session", "value": params["value"]]
        default: return [:]
        }
    }
}
