import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  var chatLauncherGroups: [CompanionAgentGroup] {
    guard let id = selectedFolderID, let folder = state.folders[id], let owner = folder.execution?.workspaceID else { return launcherGroups }
    return launcherGroups.compactMap { group in
      var group = group
      group.agents = group.agents.filter { agent in
        agent.workspaceID == "local" ? owner.hasPrefix("device:") : routeOwnsFolder(workspaceID: agent.workspaceID, folderID: id)
      }
      return group.agents.isEmpty ? nil : group
    }
  }
  var folderWorkspaces: [CompanionExecutionWorkspace] { executionWorkspaces.filter { $0.kind == .mac || $0.kind == .linux } }
  func routeOwnsFolder(workspaceID: String, folderID: String?) -> Bool {
    guard let folderID, let binding = state.folders[folderID]?.execution else { return true }
    let owner = workspaceID == "central" ? folderWorkspaces.first(where: { $0.capabilities.contains("history.central.v1") })?.id : workspaceID
    return binding.workspaceID == owner
  }
  static let deviceConnectionMessage = "Can’t connect to this device. Make sure it’s online and connected to the internet."
  func workspaceIsConnected(_ id: String) -> Bool {
    if id == "local" { return true }
    if id == "central" { return online && engine != nil && transport != nil }
    return workspaceReachable[id] == true && workspaceClients[id] != nil
  }
  func workspaceActionMessage(_ error: any Error) -> String {
    if error is URLError { return Self.deviceConnectionMessage }
    if let connection = error as? MobileConnectionError {
      switch connection {
      case .offline: return Self.deviceConnectionMessage
      case .http(let code, _) where [502, 503, 504].contains(code): return Self.deviceConnectionMessage
      default: break
      }
    }
    return error.localizedDescription
  }
  /// Confirm the owner is reachable before recording a new remote creation.
  /// A later interrupted reply still uses its original identity on an in-place retry.
  func requireWorkspaceConnection(_ id: String) async throws {
    guard workspaceIsConnected(id) else { throw DeviceExecutionError.unavailable(Self.deviceConnectionMessage) }
    if id == "local" { return }
    if id == "central", let transport {
      let identity = try await transport.workspaceIdentity()
      guard identity == state.workspaceID else { throw MobileStore.Failure.wrongWorkspace }
    } else if let client = workspaceClients[id] { try await client.checkConnection() }
  }
  func newWorkspaceFolder(name: String, workspaceID: String, id: String = UUID().uuidString.lowercased()) async throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 4096 else { throw DeviceExecutionError.unavailable("Enter a folder name of up to 4,096 bytes.") }
    try await requireWorkspaceConnection(workspaceID)
    guard let client = workspaceClients[workspaceID], let store else { throw MobileConnectionError.offline }
    var saved = await store.snapshot().workspaceFolderRequests?[workspaceID]
    if let previous = saved, previous.title != name {
      // Recover an interrupted earlier creation here, without a separate queue UI.
      _ = try await client.createFolder(previous)
      saved = nil
    }
    let mutation = saved ?? CompanionMutation(operationID: id, deviceID: state.deviceID, kind: .createFolder, resourceID: id, title: name)
    try await store.rememberWorkspaceFolder(mutation, workspaceID: workspaceID)
    let folder = try await client.createFolder(mutation)
    await reload(); openFolder(folder.id)
  }
  func prepareExecutionFolder(_ folderID: String?, workspaceID: String) async throws {
    guard let folderID, let folder = state.folders[folderID] else { return }
    guard routeOwnsFolder(workspaceID: workspaceID, folderID: folderID) else {
      throw DeviceExecutionError.unavailable("Choose an agent in this folder’s owning workspace.")
    }
    if workspaceID != "central", let client = workspaceClients[workspaceID] {
      if let existing = try await client.folders().first(where: { $0.id == folderID }) {
        guard existing.execution == folder.execution else { throw MobileStore.Failure.wrongWorkspace }
        return
      }
      _ = try await client.createFolder(.init(operationID: folder.id, deviceID: state.deviceID, kind: .createFolder, resourceID: folder.id, title: folder.name, folderExecution: folder.execution))
    }
  }
}
