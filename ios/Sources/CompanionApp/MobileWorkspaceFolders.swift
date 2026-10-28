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
  func newWorkspaceFolder(name: String, workspaceID: String, id: String = UUID().uuidString.lowercased()) async throws {
    guard let client = workspaceClients[workspaceID], workspaceReachable[workspaceID] == true else { throw MobileConnectionError.offline }
    guard let store else { throw MobileConnectionError.offline }
    let saved = await store.snapshot().workspaceFolderRequests?[workspaceID]
    if let saved, saved.title != name { throw DeviceExecutionError.unavailable("An earlier folder creation needs acknowledgement. Open Settings → Pending changes before creating another folder in this workspace.") }
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
