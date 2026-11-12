import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Mac scoped execution", .serialized)
@MainActor
struct MacExecutionTests {
  let deviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-execution-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
  }

  @Test("a manually paired Dev can withdraw presence over its authenticated library connection")
  func remoteDevelopmentDisconnect() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let library = try await db.libraryWorkspaceID()
    let auth = try DeviceAuthentication(fileURL: dir.appendingPathComponent("paired.json"))
    let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter")!)
    let pairing = try await auth.pair(.init(token: offer.payload.token, deviceID: deviceID, deviceName: "Remote Mac",
      metadata: .init(kind: .mac, developmentInstance: "review")), workspaceID: library)
    #expect(await auth.deviceConnections().first?.name == "Remote Mac (Dev)")
    let api = LibraryWorkspaceAPI(database: db, authentication: auth, commands: ScopedCommands(), isActive: { true })
    let response = await api.handle(.init(method: "POST", target: "/v1/devices/development/disconnect",
      headers: ["authorization": "Bearer " + pairing.credential, "x-woven-protocol": String(LibraryProtocol.version), "x-woven-workspace": library]))
    #expect(response.status == 200)
    #expect(await auth.devices().isEmpty)
    // Presence withdrawal preserves pairing identity; a new request can reconnect.
    #expect(try await auth.authenticate(bearer: pairing.credential).id == deviceID)
    #expect(await auth.devices().count == 1)
  }

  @Test("workspace access follows enrollment while token revocation still prevents dispatch")
  func automaticAccessAndRevocation() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.libraryIdentity()
    let auth = try ExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", executionDeviceID: identity.hostDeviceID)
    _ = try await db.registerExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = MacExecutionAPI(database: db, commands: commands, authentication: auth, descriptor: workspace, isActive: { true })
    let credential = try await api.provision(deviceID: deviceID)
    let headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(LibraryProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let command = LibraryCommand(deviceID: deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let accepted = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(command)))
    #expect(accepted.status == 200 && commands.accepted == [command])
    try await api.revoke(deviceID: deviceID)
    let revoked = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(command)))
    #expect(revoked.status == 401 && commands.accepted == [command])
  }

  @Test("direct Mac route never dispatches remote workspace commands or another device's receipt")
  func localRouting() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.libraryIdentity()
    let auth = try ExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", capabilities: ["history.central.v1"], executionDeviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = MacExecutionAPI(database: db, commands: commands, authentication: auth, descriptor: workspace, isActive: { true })
    let credential = try await api.provision(deviceID: deviceID)
    let tokenFile = dir.appendingPathComponent("tokens.json")
    #expect(!(try String(contentsOf: tokenFile, encoding: .utf8)).contains(credential.token))
    let restarted = try ExecutionAuthentication(fileURL: tokenFile)
    let scope = try await restarted.authenticate(bearer: credential.token)
    #expect(scope.deviceID == deviceID && scope.libraryID == identity.libraryID && scope.workspaceID == workspace.id)
    var headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(LibraryProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let providersResponse = await api.handle(.init(method: "GET", target: "/wovenmatter/v1/execution/providers", headers: headers))
    let providers = try JSONDecoder().decode([HarnessCapabilities].self, from: providersResponse.body)
    #expect(providers.map(\.id) == ["local:default_agent"])
    let remote = LibraryCommand(deviceID: deviceID, kind: .createSession, providerID: "remote:other:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let rejected = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(remote)))
    #expect(rejected.status == 403 && commands.accepted.isEmpty)
    let local = LibraryCommand(deviceID: deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let accepted = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(local)))
    #expect(accepted.status == 200 && commands.accepted == [local])
    headers["x-woven-device"] = UUID().uuidString.lowercased()
    let crossed = await api.handle(.init(method: "GET", target: "/v1/execution/commands/\(local.commandID)", headers: headers))
    #expect(crossed.status == 403 && commands.receiptReads == 0)
    try await restarted.revoke(deviceID: deviceID)
    let revoked = try ExecutionAuthentication(fileURL: tokenFile)
    await #expect(throws: LibraryAPIError.self) { try await revoked.authenticate(bearer: credential.token) }
  }
}

@MainActor
private final class ScopedCommands: LibraryCommandServing {
  var accepted: [LibraryCommand] = []
  var receiptReads = 0
  func providers() -> [HarnessCapabilities] {
    [HarnessCapabilities(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi", available: true),
     HarnessCapabilities(id: "remote:other:default_agent", runtimeKind: "default_agent", displayName: "Remote", available: true)]
  }
  func pendingInteractions() async -> [PendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) async throws -> HarnessCapabilities { providers()[0] }
  func transcript(conversationID: String, before: String?) async throws -> LibraryTranscript { .init(conversationID: conversationID) }
  func receipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt? { receiptReads += 1; return nil }
  func execute(_ command: LibraryCommand, deviceID: String) async throws -> LibraryCommandReceipt {
    accepted.append(command)
    return .init(commandID: command.commandID, deviceID: deviceID, status: .completed)
  }
}
