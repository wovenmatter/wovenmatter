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

  @Test("disabled central execution policy rejects an already-issued token without dispatch")
  func policyRevocation() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity()
    let auth = try CompanionExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", executionDeviceID: identity.hostDeviceID)
    _ = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = CompanionMacExecutionAPI(database: db, commands: commands, authentication: auth, descriptor: workspace, isActive: { true },
      authorizeDevice: { id in
        guard try await db.companionWorkspaceAccessAllowed(deviceID: id, workspaceID: workspace.id) else {
          throw CompanionAPIError(code: "execution_disabled", message: "Disabled")
        }
      })
    let credential = try await api.provision(deviceID: deviceID)
    try await db.setCompanionWorkspaceAccess(deviceID: deviceID, workspaceID: workspace.id, enabled: false, authorizedBy: identity.hostDeviceID)
    let headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(CompanionProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let command = CompanionCommand(deviceID: deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let denied = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(command)))
    #expect(denied.status == 403 && commands.accepted.isEmpty)
    await #expect(throws: CompanionAPIError.self) { try await api.provision(deviceID: deviceID) }
  }

  @Test("folder creation allocates a Mac-owned root and rejects cross-device and cross-workspace writes")
  func ownedFolders() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity()
    let auth = try CompanionExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac")
    let api = CompanionMacExecutionAPI(database: db, commands: ScopedCommands(), authentication: auth, descriptor: workspace, isActive: { true })
    let credential = try await api.provision(deviceID: deviceID)
    let headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(CompanionProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let id = UUID().uuidString.lowercased()
    let mutation = CompanionMutation(deviceID: deviceID, kind: .createFolder, resourceID: id, title: "From iPhone")
    let request = CompanionHTTPRequest(method: "POST", target: "/v1/execution/folders", headers: headers, body: try JSONEncoder().encode(mutation))
    let first = await api.handle(request), retry = await api.handle(request)
    #expect(first.status == 200 && retry.status == 200)
    let folder = try JSONDecoder().decode(CompanionFolder.self, from: first.body)
    #expect(folder.execution?.workspaceID == workspace.id)
    #expect(FileManager.default.fileExists(atPath: try #require(folder.execution?.rootPath)))
    let read = await api.handle(.init(method: "GET", target: "/v1/execution/folders", headers: headers))
    #expect(try JSONDecoder().decode([CompanionFolder].self, from: read.body) == [folder])
    var cross = mutation; cross.resourceID = UUID().uuidString.lowercased(); cross.folderExecution = .init(workspaceID: UUID().uuidString.lowercased(), rootPath: "/tmp")
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: headers, body: try JSONEncoder().encode(cross))).status == 403)
    var wrongDevice = headers; wrongDevice["x-woven-device"] = UUID().uuidString.lowercased()
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: wrongDevice, body: try JSONEncoder().encode(mutation))).status == 403)
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
    let tokenFile = dir.appendingPathComponent("tokens.json")
    #expect(!(try String(contentsOf: tokenFile, encoding: .utf8)).contains(credential.token))
    let restarted = try CompanionExecutionAuthentication(fileURL: tokenFile)
    let scope = try await restarted.authenticate(bearer: credential.token)
    #expect(scope.deviceID == deviceID && scope.libraryID == identity.libraryID && scope.workspaceID == workspace.id)
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
    try await restarted.revoke(deviceID: deviceID)
    let revoked = try CompanionExecutionAuthentication(fileURL: tokenFile)
    await #expect(throws: CompanionAPIError.self) { try await revoked.authenticate(bearer: credential.token) }
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
