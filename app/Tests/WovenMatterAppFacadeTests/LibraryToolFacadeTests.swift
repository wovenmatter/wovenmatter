import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct LibraryToolFacadeTests {
    @Test func pairedDeviceControlsEveryWorkspace() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let identity = try await fixture.database.libraryIdentity()
        let localID = UUID().uuidString.lowercased()
        _ = try await fixture.database.registerExecutionWorkspace(.init(workspace: .init(
            id: localID, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .mac, name: "Paired workspace", executionDeviceID: identity.hostDeviceID)),
            deviceID: identity.hostDeviceID)
        // The Linux host's chat runs on its server; this Mac relays the phone's send there.
        let (_, linux) = try await fixture.enrollLinuxHost()
        let device = fixture.device
        try await fixture.database.requireLibraryAutomationAccess(callerID: caller)
        let localChat = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        let remoteChat = try #require(await fixture.model.createRemoteACPSession(target: try fixture.linuxTarget()))
        for chat in [localChat, remoteChat] {
            let response = try await fixture.model.libraryCommands.executeTool(.init(conversationID: caller,
                request: .init(arguments: ["sessions", "manage", chat, "--purpose", "Shared access"]),
                enabledGroups: WorkspaceToolGroup.allCases), deviceID: device)
            #expect(response.success, "\(response.error ?? "")")
            let command = LibraryCommand(deviceID: device, kind: .send,
                conversationID: chat, text: "Run through the provider-free fixture")
            let receipt = try await fixture.model.libraryCommands.execute(command, deviceID: device)
            #expect(receipt.status == .completed, "\(receipt.message ?? "")")
        }
        #expect(await fixture.recorder.deliveries.count == 1)
        #expect(await linux.commands.contains { $0.kind == .send && $0.conversationID == remoteChat })
    }

    @Test func importedPhoneCallerUsesActualNotesCalendarAndHistoryWithoutProvider() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        func request(_ arguments: [String]) -> LibraryToolRequest {
            .init(conversationID: caller, request: .init(arguments: arguments), enabledGroups: WorkspaceToolGroup.allCases)
        }
        let create = request(["notes", "create", "--title", "From phone", "--kind", "html"])
        let result = try await fixture.model.libraryCommands.executeTool(create, deviceID: fixture.device)
        #expect(result.success, "\(result.error ?? "")")
        let noteID = try #require(result.result?.objectValue?["id"]?.stringValue)
        #expect(try await fixture.database.libraryNote(id: noteID)?.kind == .html)
        let read = try await fixture.model.libraryCommands.executeTool(request(["notes", "read", noteID]), deviceID: fixture.device)
        #expect(read.success && read.result?.objectValue?["kind"]?.stringValue == "html", "\(read.error ?? "")")
        let calendar = try await fixture.model.libraryCommands.executeTool(request([
            "calendar", "create", "--title", "Phone event", "--starts-at", "2026-12-01T12:00:00Z"
        ]), deviceID: fixture.device)
        #expect(calendar.success, "\(calendar.error ?? "")")
        let listed = try await fixture.model.libraryCommands.executeTool(request(["calendar", "list"]), deviceID: fixture.device)
        #expect(listed.success, "\(listed.error ?? "")")
        let history = try await fixture.model.libraryCommands.executeTool(request(["history", "conversations"]), deviceID: fixture.device)
        #expect(history.success, "\(history.error ?? "")")
        let replay = try await fixture.model.libraryCommands.executeTool(create, deviceID: fixture.device)
        #expect(replay.result == result.result)
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
        #expect(try await fixture.database.librarySnapshot().notes.count == 1)
    }

    /// A phone that pairs with its member key becomes a member; its signed
    /// requests then work without the bearer, until a Mac removes it.
    @Test func phonePairedWithAMemberKeySignsItsRequests() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let auth = try DeviceAuthentication(fileURL: fixture.directory.appending(path: "member-devices.json"))
        let mac = MemberDirectory(database: fixture.database, identity: try MemberIdentity.loadOrCreate(
            file: fixture.directory.appending(path: "mac.key"), deviceID: try await fixture.database.libraryIdentity().hostDeviceID, kind: .mac), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let phone = try MemberIdentity.loadOrCreate(file: fixture.directory.appending(path: "phone.key"), deviceID: UUID().uuidString.lowercased(), kind: .ios)
        let api = DeviceAPI(database: fixture.database, authentication: auth, commands: fixture.model.libraryCommands,
            isActive: { true }, members: mac, onMemberPaired: { id, name, key in
                _ = try? await mac.add(deviceID: id, kind: .ios, name: name, publicKey: key, endpoints: [])
            })
        let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.ts.net/wovenmatter")!)
        var pair = PairRequest(token: offer.payload.token, deviceID: phone.deviceID, deviceName: "Member phone", metadata: .init(kind: .iPhone),
                               requiresConfirmation: true)
        pair.memberPublicKey = phone.publicKey
        let paired = await api.handle(.init(method: "POST", target: "/v1/pair", headers: [:], body: try JSONEncoder().encode(pair)))
        #expect(paired.status == 200)
        // The reply names the Mac's member device ID: the phone's audience.
        let reply = try JSONDecoder().decode(PairResponse.self, from: paired.body)
        #expect(reply.hostDeviceID == mac.identity.deviceID)
        // Confirming the pairing signs the phone's member entry.
        #expect(await mac.member(phone.deviceID) == nil)
        let confirmed = await api.handle(.init(method: "POST", target: "/v1/pair/confirm", headers: [
            "authorization": "Bearer " + reply.credential, "x-woven-protocol": String(LibraryProtocol.version),
            "x-woven-workspace": reply.workspaceID], body: Data()))
        #expect(confirmed.status == 200)
        #expect(await mac.member(phone.deviceID)?.kind == .ios)
        func hello() async throws -> Int {
            var headers = try phone.signer.headers(method: "GET", target: "/wovenmatter/v1/hello", audience: mac.identity.deviceID)
            headers["X-Woven-Protocol"] = String(LibraryProtocol.version)
            let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            return await api.handle(.init(method: "GET", target: "/wovenmatter/v1/hello", headers: lowered)).status
        }
        #expect(try await hello() == 200)
        try await mac.remove(phone.deviceID)
        #expect(try await hello() == 401)
    }

    /// The member entry is signed when the phone confirms; a refusal reaches
    /// the phone before the code is spent; pairing again (a phone restored
    /// from a backup has a new key) replaces the key.
    @Test func phoneMemberIsAddedAtConfirmationAndRefusalsReachThePhone() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let auth = try DeviceAuthentication(fileURL: fixture.directory.appending(path: "member-devices.json"))
        let mac = MemberDirectory(database: fixture.database, identity: try MemberIdentity.loadOrCreate(
            file: fixture.directory.appending(path: "mac.key"), deviceID: try await fixture.database.libraryIdentity().hostDeviceID, kind: .mac), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let api = DeviceAPI(database: fixture.database, authentication: auth, commands: fixture.model.libraryCommands,
            isActive: { true }, members: mac, onMemberPaired: { id, name, key in
                try await mac.add(deviceID: id, kind: .ios, name: name, publicKey: key, endpoints: [], replacingKey: true)
            })
        let workspaceID = try await fixture.database.libraryID()
        let phoneID = UUID().uuidString.lowercased()
        func pair(_ device: String, key: Data) async throws -> LibraryHTTPResponse {
            let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.ts.net/wovenmatter")!)
            var request = PairRequest(token: offer.payload.token, deviceID: device, deviceName: "Member phone",
                                               metadata: .init(kind: .iPhone), requiresConfirmation: true)
            request.memberPublicKey = key
            return await api.handle(.init(method: "POST", target: "/v1/pair", headers: [:], body: try JSONEncoder().encode(request)))
        }
        func confirm(_ paired: LibraryHTTPResponse) async throws -> Int {
            let reply = try JSONDecoder().decode(PairResponse.self, from: paired.body)
            return await api.handle(.init(method: "POST", target: "/v1/pair/confirm", headers: [
                "x-woven-protocol": String(LibraryProtocol.version), "x-woven-workspace": workspaceID,
                "authorization": "Bearer " + reply.credential])).status
        }
        let first = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let paired = try await pair(phoneID, key: first)
        #expect(paired.status == 200)
        #expect(try JSONDecoder().decode(PairResponse.self, from: paired.body).libraryIDs != nil)
        #expect(await mac.member(phoneID) == nil, "not a member before it confirms")
        #expect(try await confirm(paired) == 200)
        #expect(await mac.member(phoneID)?.publicKey == first)
        // A device ID that belongs to a Mac member is refused with the reason.
        let otherMac = UUID().uuidString.lowercased()
        try await mac.add(deviceID: otherMac, kind: .mac, name: "Other", publicKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), endpoints: [])
        let refused = try await pair(otherMac, key: first)
        #expect(refused.status == 409)
        #expect(try JSONDecoder().decode(LibraryAPIError.self, from: refused.body).code == "member_key_changed")
        // Restored from a backup: the Mac removes the old pairing, the phone pairs again with a new key.
        try await auth.revoke(deviceID: phoneID)
        let restored = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let again = try await pair(phoneID, key: restored)
        #expect(again.status == 200)
        #expect(try await confirm(again) == 200)
        #expect(await mac.member(phoneID)?.publicKey == restored)
    }

    @Test func httpEndpointUsesTheSignedMemberAndCurrentMembership() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await importPhone(fixture)
        let auth = try DeviceAuthentication(fileURL: fixture.directory.appending(path: "test-devices.json"))
        let workspaceID = try await fixture.database.libraryID()
        let mac = MemberDirectory(database: fixture.database, identity: MemberIdentity(
            deviceID: try await fixture.database.libraryIdentity().hostDeviceID, kind: .mac, key: .init()), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let phone = MemberIdentity(deviceID: fixture.device, kind: .ios, key: .init())
        _ = try await mac.add(deviceID: phone.deviceID, kind: .ios, name: "Fixture phone", publicKey: phone.publicKey, endpoints: [])
        let api = DeviceAPI(database: fixture.database, authentication: auth,
            commands: fixture.model.libraryCommands, isActive: { true }, members: mac)
        let call: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("woven_notes_list"), "arguments": .object([:])])])
        let body = try JSONEncoder().encode(call)
        var headers = ["x-woven-protocol": String(LibraryProtocol.version), "x-woven-workspace": workspaceID,
            "x-woven-conversation-id": caller, "x-woven-enabled-groups": "notes"]
        func send(_ target: String, signed: Bool = true) async throws -> LibraryHTTPResponse {
            var request = headers
            if signed {
                for (name, value) in try phone.signer.headers(method: "POST", target: target, body: body, audience: mac.identity.deviceID) {
                    request[name.lowercased()] = value
                }
            }
            return await api.handle(.init(method: "POST", target: target, headers: request, body: body))
        }
        #expect(try await send("/mcp", signed: false).status == 401)
        // A pairing bearer reaches nothing but its own confirmation and unpair.
        let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.ts.net/wovenmatter")!)
        let paired = try await auth.pairConfirmed(.init(token: offer.payload.token, deviceID: UUID().uuidString.lowercased(),
            deviceName: "Bearer phone", protocolVersion: LibraryProtocol.version), workspaceID: workspaceID)
        headers["authorization"] = "Bearer " + paired.credential
        #expect(try await send("/mcp", signed: false).status == 401)
        headers.removeValue(forKey: "authorization")
        let accepted = try await send("/wovenmatter/mcp")
        #expect(accepted.status == 200)
        let result = try JSONDecoder().decode(JSONValue.self, from: accepted.body)
        #expect(result.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        // A newer phone that knows one more tool group keeps the tools of the
        // groups this Mac knows; the unknown name alone enables nothing.
        headers["x-woven-enabled-groups"] = "notes,holograms"
        let newer = try await send("/wovenmatter/mcp")
        #expect(newer.status == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: newer.body).objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        headers["x-woven-enabled-groups"] = "holograms"
        let unknownOnly = try await send("/wovenmatter/mcp")
        #expect(unknownOnly.status == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: unknownOnly.body).objectValue?["result"]?.objectValue?["isError"] != .bool(false))
        headers["x-woven-enabled-groups"] = "notes"
        headers["x-woven-conversation-id"] = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Unrelated Mac chat", ownerDeviceID: UUID())
        #expect(try await send("/mcp").status == 403)
        headers["x-woven-conversation-id"] = caller
        _ = try await mac.remove(phone.deviceID)
        #expect(try await send("/mcp").status == 401)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func libraryToolRevocationFencesAutomationEvenAfterReenable() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Mac caller", ownerDeviceID: UUID())
        try await fixture.database.setSessionTools(.init(enabled: [.browser, .computer]), sessionID: caller)
        let call = WovenMatterToolRequest(arguments: ["browser", "call", "--json", "{\"action\":\"tabs\"}"])
        let tools = try #require(fixture.model.agentTools)
        #expect(await tools.handle(call, callerID: caller).success)
        for enabled in [["browser"], ["browser", "computer"]] {
            let command = LibraryCommand(deviceID: fixture.device, kind: .workspace,
                workspaceAction: .sessionTools(id: caller, enabled: enabled, confirmPausingTimers: true))
            #expect(try await fixture.model.libraryCommands.execute(command, deviceID: fixture.device).status == .completed)
        }
        #expect(try await fixture.database.sessionTools(caller).enabled.contains(.computer))
        await #expect(throws: (any Error).self) {
            try await fixture.database.requireAutomationRequest(.browser, callerID: caller, requestID: call.requestID)
        }
    }

    private func importPhone(_ fixture: FacadeFixture) async throws -> String {
        let identity = try await fixture.database.libraryIdentity()
        let caller = UUID().uuidString.lowercased()
        let workspace = try await fixture.database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: fixture.device,
            kind: .ios, name: "Phone", executionDeviceID: fixture.device)), deviceID: fixture.device)
        _ = try await fixture.database.ingestExecutionJournal(.init(libraryID: identity.libraryID, entries: [
            .init(workspaceID: workspace.id, originSequence: 1, conversationID: caller, kind: .conversation,
                  conversation: .init(id: caller, title: "Phone chat", runtimeKind: "piDurable"))
        ]), deviceID: fixture.device)
        return caller
    }
}
