import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Mac scoped execution", .serialized)
@MainActor
struct MacExecutionTests {
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-execution-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
  }

  /// This Mac's member directory with one phone member, and a request signer for that phone.
  func members(_ db: WorkspaceDatabase) async throws -> (MemberDirectory, MemberIdentity, String) {
    let identity = try await db.libraryIdentity()
    let directory = MemberDirectory(database: db, identity: MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init()), cacheLifetime: 0)
    try await directory.ensureSelf(name: "Mac", endpoints: [])
    let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
    try await directory.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: phone.publicKey, endpoints: [])
    return (directory, phone, identity.hostDeviceID)
  }

  func signed(_ member: MemberIdentity, audience: String, workspace: ExecutionWorkspace, method: String, target: String, body: Data = Data()) throws -> LibraryHTTPRequest {
    var headers = try member.signer.headers(method: method, target: target, body: body, audience: audience)
    headers["X-Woven-Protocol"] = String(LibraryProtocol.version); headers["X-Woven-Workspace"] = workspace.id
    return .init(method: method, target: target, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }), body: body)
  }

  @Test("a signed member controls local sessions until it is removed, and a bearer is refused")
  func signedAccessAndRemoval() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.libraryIdentity()
    let (members, phone, host) = try await members(db)
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", executionDeviceID: identity.hostDeviceID)
    _ = try await db.registerExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = MacExecutionAPI(database: db, commands: commands, descriptor: workspace, isActive: { true }, members: members)
    let command = LibraryCommand(deviceID: phone.deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let body = try JSONEncoder().encode(command)
    let accepted = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "POST", target: "/v1/execution/commands", body: body))
    #expect(accepted.status == 200 && commands.accepted == [command])
    let bearer = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: ["authorization": "Bearer " + String(repeating: "a", count: 43),
      "x-woven-protocol": String(LibraryProtocol.version), "x-woven-workspace": workspace.id], body: body))
    #expect(bearer.status == 401 && commands.accepted == [command])
    _ = try await members.remove(phone.deviceID)
    let removed = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "POST", target: "/v1/execution/commands", body: body))
    #expect(removed.status == 401 && commands.accepted == [command])
  }

  @Test("direct Mac route never dispatches remote workspace commands or another device's receipt")
  func localRouting() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.libraryIdentity()
    let (members, phone, host) = try await members(db)
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", capabilities: ["history.library.v1"], executionDeviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = MacExecutionAPI(database: db, commands: commands, descriptor: workspace, isActive: { true }, members: members)
    let providersResponse = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "GET", target: "/wovenmatter/v1/execution/providers"))
    let providers = try JSONDecoder().decode([HarnessCapabilities].self, from: providersResponse.body)
    #expect(providers.map(\.id) == ["local:default_agent"])
    let remote = LibraryCommand(deviceID: phone.deviceID, kind: .createSession, providerID: "remote:other:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let rejected = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "POST", target: "/v1/execution/commands", body: try JSONEncoder().encode(remote)))
    #expect(rejected.status == 403 && commands.accepted.isEmpty)
    let local = LibraryCommand(deviceID: phone.deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let accepted = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "POST", target: "/v1/execution/commands", body: try JSONEncoder().encode(local)))
    #expect(accepted.status == 200 && commands.accepted == [local])
    // Another device's command identity is never dispatched under this member's signature.
    let crossed = LibraryCommand(deviceID: UUID().uuidString.lowercased(), kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let refused = await api.handle(try signed(phone, audience: host, workspace: workspace, method: "POST", target: "/v1/execution/commands", body: try JSONEncoder().encode(crossed)))
    #expect(refused.status == 403 && commands.accepted == [local])
  }
}

@MainActor
private final class ScopedCommands: DeviceCommandServing {
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
