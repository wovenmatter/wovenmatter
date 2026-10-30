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

  @Test("a manually paired Dev can withdraw presence over its authenticated library connection")
  func remoteDevelopmentDisconnect() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let library = try await db.companionWorkspaceID()
    let auth = try CompanionAuthentication(fileURL: dir.appendingPathComponent("paired.json"))
    let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter")!)
    let pairing = try await auth.pair(.init(token: offer.payload.token, deviceID: deviceID, deviceName: "Remote Mac",
      metadata: .init(kind: .mac, developmentInstance: "review")), workspaceID: library)
    #expect(await auth.deviceConnections().first?.name == "Remote Mac (Dev)")
    let api = CompanionWorkspaceAPI(database: db, authentication: auth, commands: ScopedCommands(), isActive: { true })
    let response = await api.handle(.init(method: "POST", target: "/v1/devices/development/disconnect",
      headers: ["authorization": "Bearer " + pairing.credential, "x-woven-protocol": String(CompanionProtocol.version), "x-woven-workspace": library]))
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
    let identity = try await db.companionLibraryIdentity()
    let auth = try CompanionExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", executionDeviceID: identity.hostDeviceID)
    _ = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let commands = ScopedCommands()
    let api = CompanionMacExecutionAPI(database: db, commands: commands, authentication: auth, descriptor: workspace, isActive: { true })
    let credential = try await api.provision(deviceID: deviceID)
    let headers = ["authorization": "Bearer " + credential.token, "x-woven-protocol": String(CompanionProtocol.version),
      "x-woven-library": identity.libraryID, "x-woven-workspace": workspace.id, "x-woven-device": deviceID]
    let command = CompanionCommand(deviceID: deviceID, kind: .createSession, providerID: "local:default_agent", libraryID: identity.libraryID, workspaceID: workspace.id)
    let accepted = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(command)))
    #expect(accepted.status == 200 && commands.accepted == [command])
    try await api.revoke(deviceID: deviceID)
    let revoked = await api.handle(.init(method: "POST", target: "/v1/execution/commands", headers: headers, body: try JSONEncoder().encode(command)))
    #expect(revoked.status == 401 && commands.accepted == [command])
  }

  @Test("folder creation allocates a Mac-owned root and rejects cross-device and cross-workspace writes")
  func ownedFolders() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity()
    let auth = try CompanionExecutionAuthentication(fileURL: dir.appendingPathComponent("tokens.json"))
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", capabilities: ["history.central.v1"],
      executionDeviceID: identity.hostDeviceID, contentWorkspaceID: "device:" + deviceID)
    _ = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    try await db.bindDeviceOwnership(ownerDeviceID: UUID(uuidString: deviceID)!)
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
    #expect(folder.execution?.workspaceID == "device:" + deviceID)
    #expect(FileManager.default.fileExists(atPath: try #require(folder.execution?.rootPath)))
    let read = await api.handle(.init(method: "GET", target: "/v1/execution/folders", headers: headers))
    #expect(try JSONDecoder().decode([CompanionFolder].self, from: read.body) == [folder])
    #expect(CompanionWorkspaceIdentity.canonicalID(workspace.id, workspaces: [workspace]) == deviceID)
    #expect(CompanionWorkspaceIdentity.canonicalID(identity.hostDeviceID, workspaces: [workspace]) == deviceID)
    #expect(try await db.executionWorkspaceMatches(captured: workspace.id, expected: "device:" + deviceID))
    let native = try await db.createNote(folderID: nil)
    #expect(try await db.companionSnapshot().notes.first { $0.id == native }?.workspaceID == deviceID)
    // Known folder retries retain the exact root; unknown requests cannot choose a host path.
    var known = mutation; known.folderExecution = folder.execution
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: headers, body: try JSONEncoder().encode(known))).status == 200)
    known.resourceID = UUID().uuidString.lowercased()
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: headers, body: try JSONEncoder().encode(known))).status == 403)
    let legacyID = UUID()
    _ = try await db.createFolder(id: legacyID, name: "Legacy", location: .init(workspaceID: workspace.id, rootPath: dir.path, managed: false))
    let listed = await api.handle(.init(method: "GET", target: "/v1/execution/folders", headers: headers))
    #expect(try JSONDecoder().decode([CompanionFolder].self, from: listed.body).contains { $0.id == legacyID.uuidString.lowercased() })
    // A foreign registrant's display alias cannot authorize native execution.
    let foreignID = UUID().uuidString.lowercased()
    let foreign = CompanionExecutionWorkspace(id: foreignID, libraryID: identity.libraryID, ownerDeviceID: foreignID,
      kind: .mac, name: "Foreign", capabilities: ["history.central.v1"], executionDeviceID: foreignID, contentWorkspaceID: "device:" + deviceID)
    await #expect(throws: CompanionAPIError.self) {
      try await db.registerCompanionExecutionWorkspace(.init(workspace: foreign), deviceID: foreignID)
    }
    #expect(try await db.executionWorkspaceMatches(captured: foreignID, expected: "device:" + deviceID) == false)
    var cross = mutation; cross.resourceID = UUID().uuidString.lowercased(); cross.folderExecution = .init(workspaceID: UUID().uuidString.lowercased(), rootPath: "/tmp")
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: headers, body: try JSONEncoder().encode(cross))).status == 403)
    var wrongDevice = headers; wrongDevice["x-woven-device"] = UUID().uuidString.lowercased()
    #expect(await api.handle(.init(method: "POST", target: "/v1/execution/folders", headers: wrongDevice, body: try JSONEncoder().encode(mutation))).status == 403)
  }

  @Test("coalesced unfiling and recovery retain the last explicit note workspace")
  func noteOwnershipMovesAndRecovery() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let content = try NoteDocument(blocks: [.richText(.init(text: "Writing"))]).encoded()
    let id = try await db.createNote(folderID: nil, title: "Note", content: content, workspaceID: deviceID)
    let before = try #require(try await db.companionSnapshot().notes.first { $0.id == id })
    let destination = UUID().uuidString.lowercased()
    let mutation = CompanionMutation(deviceID: deviceID, kind: .updateNote, resourceID: id, expectedRevision: before.revision,
      title: before.title, content: before.content, noteWorkspaceID: destination)
    let result = try await db.applyCompanionMutation(mutation)
    #expect(result.status == .accepted)
    #expect(result.note?.workspaceID == destination)
    let recovery = try await db.preserveRecoveryCopy(sourceID: id, title: before.title, content: content, folderID: nil)
    #expect(try await db.companionSnapshot().notes.first { $0.id == recovery }?.workspaceID == destination)
  }

  @Test("registration repairs an absent content identity and older writers cannot erase or replace it")
  func retainedContentIdentity() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity()
    var workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac")
    let original = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    let oldBytes = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(CompanionExecutionWorkspace.self, from: oldBytes).contentWorkspaceID == nil)
    workspace.contentWorkspaceID = "device:" + deviceID
    let repaired = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: original.revision), deviceID: identity.hostDeviceID)
    workspace.contentWorkspaceID = nil; workspace.name = "Renamed"
    let renamed = try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: repaired.revision), deviceID: identity.hostDeviceID)
    #expect(renamed.contentWorkspaceID == repaired.contentWorkspaceID)
    workspace.contentWorkspaceID = "device:" + UUID().uuidString.lowercased()
    await #expect(throws: CompanionAPIError.self) {
      try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: renamed.revision), deviceID: identity.hostDeviceID)
    }
    let saved = try await db.companionExecutionWorkspaces()
    #expect(saved.first?.contentWorkspaceID == repaired.contentWorkspaceID)
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
