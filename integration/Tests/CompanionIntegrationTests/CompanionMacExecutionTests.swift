import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Mac scoped execution", .serialized)
@MainActor
struct CompanionMacExecutionTests {
  let deviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-execution-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
  }

  @Test("scoped secret survives restart, cannot cross workspace, and revokes durably")
  func scope() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("tokens.json")
    let auth = try CompanionExecutionAuthentication(fileURL: file)
    let library = UUID().uuidString.lowercased(), workspace = UUID().uuidString.lowercased()
    let token = try await auth.provision(deviceID: deviceID, libraryID: library, workspaceID: workspace)
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(token))
    let restarted = try CompanionExecutionAuthentication(fileURL: file)
    let scope = try await restarted.authenticate(bearer: token)
    #expect(scope.deviceID == deviceID && scope.libraryID == library && scope.workspaceID == workspace)
    try await restarted.revoke(deviceID: deviceID)
    let revoked = try CompanionExecutionAuthentication(fileURL: file)
    await #expect(throws: CompanionAPIError.self) { try await revoked.authenticate(bearer: token) }
  }

  @Test("direct Mac route never dispatches remote workspace commands or another device's receipt")
  func localRouting() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity()
    let auth = try CompanionExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", capabilities: ["history.central.v1"], executionDeviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = CompanionMacExecutionAPI(database: db, commands: commands, authentication: auth, descriptor: workspace, isActive: { true })
    let credential = try await api.provision(deviceID: deviceID)
    var headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(CompanionProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let providersResponse = await api.handle(.init(method: "GET", target: "/wovenmatter/v1/execution/providers", headers: headers))
    let providers = try JSONDecoder().decode([CompanionProvider].self, from: providersResponse.body)
    #expect(providers.map(\.id) == ["local:default_agent"])
    let remote = CompanionCommand(deviceID: deviceID, kind: .createSession, providerID: "remote:other:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let rejected = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(remote)))
    #expect(rejected.status == 403 && commands.accepted.isEmpty)
    let local = CompanionCommand(deviceID: deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let accepted = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(local)))
    #expect(accepted.status == 200 && commands.accepted == [local])
    headers["x-woven-device"] = UUID().uuidString.lowercased()
    let crossed = await api.handle(.init(method: "GET", target: "/v1/execution/commands/\(local.commandID)", headers: headers))
    #expect(crossed.status == 403 && commands.receiptReads == 0)
  }
}

@MainActor
private final class ScopedCommands: CompanionCommandServing {
  var accepted: [CompanionCommand] = []
  var receiptReads = 0
  func providers() -> [CompanionProvider] {
    [CompanionProvider(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi", available: true),
     CompanionProvider(id: "remote:other:default_agent", runtimeKind: "default_agent", displayName: "Remote", available: true)]
  }
  func pendingInteractions() async -> [CompanionPendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { providers()[0] }
  func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript { .init(conversationID: conversationID) }
  func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt? { receiptReads += 1; return nil }
  func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
    accepted.append(command)
    return .init(commandID: command.commandID, deviceID: deviceID, status: .completed)
  }
}
