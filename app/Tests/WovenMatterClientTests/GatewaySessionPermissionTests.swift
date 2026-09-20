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
        #expect(smart.permissionOptionMetadata["default"]?.name == "Ask for approval")
        #expect(smart.permissionOptionMetadata["default"]?.description?.contains("Smart approvals from Settings") == true)
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
        #expect(await transport.calls.filter { $0.0 == "session.activate" }.count == 5)
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

    @Test func hermesRefreshesInheritedPolicyBeforeLoweringSessionAccess() async throws {
        let transport = PermissionHermesTransport(approvalMode: "off")
        let client = makeHermes(transport)
        let initial = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        #expect(initial.configuration.permissionOptions == ["full"])
        // Model a profile change from Settings whose session.info event was missed.
        await transport.setApprovalMode("smart")
        let restored = try await client.setSessionPermission("default")
        #expect(restored.permission == "default")
        #expect(restored.permissionOptionMetadata["default"]?.name == "Ask for approval")
        #expect(restored.permissionOptionMetadata["default"]?.description?.contains("Smart approvals") == true)
        #expect(await transport.calls.filter { $0.0 == "config.set" }.allSatisfy { $0.1["key"] == "yolo" && $0.1["scope"] == "session" })
        await client.shutdown()
    }

    @Test(arguments: ["manual", "smart", "off"])
    func hermesProfileReadPreservesActualModeWithoutWriting(_ mode: String) async throws {
        let connection = profileConnection()
        let transport = ProfilePermissionHermesTransport(home: connection.home, mode: mode)
        #expect(try await HermesProfileApprovals.read(connection: connection, transport: transport) == mode)
        let calls = await transport.calls
        #expect(calls.map(\.0) == ["config.get", "config.get"])
        #expect(calls.map { $0.1 } == [["key": "profile"], ["key": "approvals.mode"]])
        #expect(await transport.disconnects == 1)
        #expect(await !transport.isConnected)
    }

    @Test(arguments: HermesProfileApprovalMode.allCases)
    func hermesProfileWriteUsesGlobalScopeAndConfirmsEffectivePolicy(_ mode: HermesProfileApprovalMode) async throws {
        let connection = profileConnection(remote: true)
        let transport = ProfilePermissionHermesTransport(home: connection.home, mode: "off")
        #expect(try await HermesProfileApprovals.set(mode, connection: connection, transport: transport) == mode.rawValue)
        let calls = await transport.calls
        #expect(calls.map(\.0) == ["config.get", "config.set", "config.get"])
        #expect(calls[1].1 == ["key": "approvals.mode", "value": .string(mode.rawValue), "scope": "global"])
        #expect(calls.allSatisfy { $0.1["session_id"].isNull && $0.1["profile"].isNull })
        #expect(connection.identityHome != connection.home)
        #expect(await transport.disconnects == 1)
    }

    @Test func hermesProfileMismatchAndUnknownPolicyFailWithoutDefaults() async throws {
        let connection = profileConnection()
        let mismatch = ProfilePermissionHermesTransport(home: "/fixture/other-profile", mode: "manual")
        await #expect(throws: (any Error).self) {
            try await HermesProfileApprovals.set(.smart, connection: connection, transport: mismatch)
        }
        #expect(await mismatch.calls.count == 1)
        #expect(await mismatch.disconnects == 1)
        let unknown = ProfilePermissionHermesTransport(home: connection.home, mode: "unknown")
        await #expect(throws: (any Error).self) {
            try await HermesProfileApprovals.read(connection: connection, transport: unknown)
        }
        #expect(await unknown.calls.allSatisfy { $0.0 == "config.get" })
        #expect(await unknown.disconnects == 1)
    }

    @Test func hermesProfileWriteRejectsAcknowledgmentWhenManagedPolicyStaysFull() async throws {
        let connection = profileConnection()
        let transport = ProfilePermissionHermesTransport(home: connection.home, mode: "off", ignoresWrite: true)
        await #expect(throws: (any Error).self) {
            try await HermesProfileApprovals.set(.manual, connection: connection, transport: transport)
        }
        #expect(await transport.calls.map(\.0) == ["config.get", "config.set", "config.get"])
        #expect(await transport.disconnects == 1)
    }

    @Test func hermesProfileWriteErrorsAreNotRetried() async throws {
        let connection = profileConnection()
        let transport = ProfilePermissionHermesTransport(home: connection.home, mode: "manual", rejectsWrite: true)
        await #expect(throws: (any Error).self) {
            try await HermesProfileApprovals.set(.smart, connection: connection, transport: transport)
        }
        #expect(await transport.calls.filter { $0.0 == "config.set" }.count == 1)
        #expect(await transport.disconnects == 1)
    }

    private func profileConnection(remote: Bool = false) -> HermesGatewayConnection {
        .init(home: "/fixture/hermes-profile", port: 1, token: "fixture", pid: 1,
            remoteWorkspaceID: remote ? UUID() : nil)
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
    private var approvalMode: String
    private let processFull: Bool
    private let omitEffectiveState: Bool
    init(processFull: Bool = false, omitEffectiveState: Bool = false, approvalMode: String = "manual") {
        self.processFull = processFull; self.omitEffectiveState = omitEffectiveState; self.approvalMode = approvalMode
    }
    func resetSessionOverride() { full = false }
    func setApprovalMode(_ mode: String) { approvalMode = mode }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false }
    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) {}
    func respond(id: String, result: HermesValue) {}
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        calls.append((method, params))
        switch method {
        case "session.create", "session.resume", "session.activate":
            let info: HermesValue = omitEffectiveState ? [:] : ["approval_mode": .string(approvalMode), "yolo": .bool(full || processFull || approvalMode == "off")]
            return ["session_id": "live", "stored_session_id": "stored", "info": info]
        case "config.get": return ["value": params["key"] == "approvals.mode" ? .string(approvalMode) : "high"]
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

private actor ProfilePermissionHermesTransport: HermesGatewayTransport {
    var epoch: String? = "fixture"
    var isConnected = false
    var calls: [(String, HermesValue)] = []
    var disconnects = 0
    private let home: String
    private var mode: String
    private let ignoresWrite: Bool
    private let rejectsWrite: Bool

    init(home: String, mode: String, ignoresWrite: Bool = false, rejectsWrite: Bool = false) {
        self.home = home; self.mode = mode; self.ignoresWrite = ignoresWrite; self.rejectsWrite = rejectsWrite
    }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false; disconnects += 1 }
    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) {}
    func respond(id: String, result: HermesValue) {}
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        calls.append((method, params))
        guard isConnected else { throw HermesGatewayError.message("Fixture disconnected") }
        if method == "config.get", params["key"] == "profile" { return ["home": .string(home)] }
        if method == "config.get", params["key"] == "approvals.mode" { return ["value": .string(mode)] }
        guard method == "config.set", params["key"] == "approvals.mode", params["scope"] == "global",
              params["session_id"].isNull, params["profile"].isNull,
              let requested = params["value"].string, ["manual", "smart"].contains(requested) else {
            throw HermesGatewayError.message("Unexpected profile configuration mutation")
        }
        if rejectsWrite { throw HermesGatewayError.message("Fixture write rejected") }
        if !ignoresWrite { mode = requested }
        return ["key": "approvals.mode", "value": .string(requested)]
    }
}
