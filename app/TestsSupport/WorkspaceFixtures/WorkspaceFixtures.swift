import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

// Existing suites create provider-free records with explicit fixture locations.
// These helpers are test-target dependencies only; production requires a root.
extension WorkspaceDatabase {
  public func createFixtureLocalACPSession(runtimeKind: AgentRuntimeKind, title: String,
      ownerDeviceID: UUID, createdAt: Date = Date(),
      openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
      importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
      requestedConversationID: UUID? = nil, allowMissingCalendarFolder: Bool = false, fixtureLocation: WorkspaceFolderLocation? = nil) async throws -> String {
    let root = try await fixtureCreationRoot(requestedConversationID, workspaceID: "device:" + ownerDeviceID.uuidString.lowercased(), explicit: fixtureLocation)
    return try await createLocalACPSession(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID,
      createdAt: createdAt, openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot,
      requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: root)
  }

  public func createFixtureRemoteACPSession(runtimeKind: AgentRuntimeKind, remoteWorkspaceID: UUID,
      remoteWorkspaceName: String, title: String, ownerDeviceID: UUID, createdAt: Date = Date(),
      openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
      requestedConversationID: UUID? = nil, allowMissingCalendarFolder: Bool = false, fixtureLocation: WorkspaceFolderLocation? = nil) async throws -> String {
    let root = try await fixtureCreationRoot(requestedConversationID, workspaceID: "remote:" + remoteWorkspaceID.uuidString.lowercased(), explicit: fixtureLocation)
    return try await createRemoteACPSession(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID,
      remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt,
      openCodeAssociation: openCodeAssociation, requestedConversationID: requestedConversationID,
      allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: root)
  }

  public func createFixtureFolder(id: UUID = UUID(), name: String, createdAt: Date = Date()) async throws -> String {
    try await createFolder(id: id, name: name, location: .init(workspaceID: "device:test",
      rootPath: FileManager.default.temporaryDirectory.appending(path: id.uuidString).path, managed: false), createdAt: createdAt)
  }

  private func fixtureCreationRoot(_ id: UUID?, workspaceID: String, explicit: WorkspaceFolderLocation?) async throws -> SessionCreationRoot {
    let configuration: WorkspaceSessionCreationConfiguration?
    if let id { configuration = try await toolSessionCreationConfiguration(targetID: id.uuidString.lowercased()) }
    else { configuration = nil }
    if let explicit { return .init(folderID: configuration?.folderID, location: explicit, defaultPath: explicit.rootPath) }
    let path = configuration?.nativeWorkingDirectory ?? FileManager.default.temporaryDirectory.path
    let location: WorkspaceFolderLocation
    if let folderID = configuration?.folderID,
       let folder = try await workspaceOverview().folders.first(where: { $0.id == folderID }),
       let owner = folder.executionWorkspaceID, let root = folder.rootPath {
      location = .init(workspaceID: owner, rootPath: root, managed: false)
    } else { location = .init(workspaceID: workspaceID, rootPath: path, managed: false) }
    return .init(folderID: configuration?.folderID, location: location, defaultPath: path)
  }
}
