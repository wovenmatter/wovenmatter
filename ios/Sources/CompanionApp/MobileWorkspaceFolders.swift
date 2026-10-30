import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  func canonicalWorkspaceID(_ id: String) -> String {
    if id == "local" || id == "device" { return CompanionWorkspaceIdentity.canonicalID(deviceWorkspaceID) }
    if id == "central", let central = executionWorkspaces.first(where: { $0.capabilities.contains("history.central.v1") }) { return CompanionWorkspaceIdentity.canonicalID(central.id) }
    return CompanionWorkspaceIdentity.canonicalID(id)
  }
  func folderOwner(_ folder: CompanionFolder) -> String? { folder.execution.map { canonicalWorkspaceID($0.workspaceID) } }
  func noteOwner(_ note: CompanionNote) -> String? {
    note.folderID.flatMap { state.folders[$0] }.flatMap(folderOwner) ?? note.workspaceID.map(canonicalWorkspaceID)
  }
  func conversationOwner(_ conversation: CompanionConversation) -> String? {
    if executionRecords[conversation.id] != nil { return canonicalWorkspaceID(deviceWorkspaceID) }
    if let owner = conversation.workspaceID ?? conversationWorkspaceIDs[conversation.id] { return canonicalWorkspaceID(owner) }
    if let folder = conversation.folderID.flatMap({ state.folders[$0] }), let owner = folderOwner(folder) { return owner }
    if let provider = conversation.providerID {
      let parts = provider.split(separator: ":")
      if parts.count == 3, parts[0] == "remote", UUID(uuidString: String(parts[1])) != nil { return canonicalWorkspaceID(String(parts[1])) }
      if providers.contains(where: { $0.id == provider }) {
        return executionWorkspaces.first(where: { $0.capabilities.contains("history.central.v1") }).map { canonicalWorkspaceID($0.id) }
      }
    }
    return nil
  }
  var folderWorkspaceGroups: [MobileFolderWorkspace] {
    let localID = canonicalWorkspaceID(deviceWorkspaceID)
    var result = [MobileFolderWorkspace(id: localID, name: deviceWorkspaceName, kind: .ios, isLocal: true)]
    for workspace in executionWorkspaces where !workspace.deleted {
      let id = canonicalWorkspaceID(workspace.id)
      guard !result.contains(where: { $0.id == id }) else { continue }
      result.append(.init(id: id, name: workspace.name, kind: workspace.kind, isLocal: false))
    }
    let observed = Set(folders.compactMap(folderOwner) + notes.compactMap(noteOwner) + conversations.compactMap(conversationOwner))
    for id in observed.sorted() where !result.contains(where: { $0.id == id }) {
      result.append(.init(id: id, name: "Unavailable workspace", kind: nil, isLocal: false))
    }
    return result
  }
  var hasUnassignedContent: Bool {
    folders.contains { folderOwner($0) == nil } || notes.contains { noteOwner($0) == nil } || conversations.contains { conversationOwner($0) == nil }
  }
  func folderAgents(in workspace: MobileFolderWorkspace) -> [CompanionAgentLauncher] {
    guard workspace.isLocal || workspace.kind != .ios else { return [] }
    return launcherAgents.filter { canonicalWorkspaceID($0.workspaceID) == workspace.id }
  }
  var chatLauncherGroups: [CompanionAgentGroup] {
    let owner = selectedFolderID.flatMap { state.folders[$0] }.flatMap(folderOwner) ?? selectedFolderWorkspaceID
    return launcherGroups.compactMap { group in
      var group = group
      group.agents = group.agents.filter { agent in
        let canonical = canonicalWorkspaceID(agent.workspaceID)
        return (owner == nil || canonical == owner) && (agent.workspaceID == "local" || !executionWorkspaces.contains { canonicalWorkspaceID($0.id) == canonical && $0.kind == .ios })
      }
      return group.agents.isEmpty ? nil : group
    }
  }
  var folderWorkspaces: [CompanionExecutionWorkspace] { executionWorkspaces.filter { $0.kind == .mac || $0.kind == .linux } }
  func routeOwnsFolder(workspaceID: String, folderID: String?) -> Bool {
    guard let folderID, let folder = state.folders[folderID], let owner = folderOwner(folder) else { return true }
    return owner == canonicalWorkspaceID(workspaceID)
  }
  var selectedFolderScopeTitle: String {
    if let id = selectedFolderID { return state.folders[id]?.name ?? "Folder" }
    if selectedFolderWorkspaceID == "unassigned" { return "Unassigned items" }
    guard let owner = selectedFolderWorkspaceID else { return "All Workspaces" }
    let name = folderWorkspaceGroups.first { $0.id == owner }?.name ?? "Workspace"
    return folderContentsUnfiled ? "Unfiled · " + name : name
  }
  func folderScopeIncludes(owner: String?, folderID: String?) -> Bool {
    if let selectedFolderID { return folderID == selectedFolderID }
    if folderContentsUnfiled && folderID != nil { return false }
    if selectedFolderWorkspaceID == "unassigned" { return owner == nil }
    return selectedFolderWorkspaceID == nil || owner == selectedFolderWorkspaceID
  }
  func workspaceRoute(for id: String) -> String {
    executionWorkspaces.first { canonicalWorkspaceID($0.id) == canonicalWorkspaceID(id) }?.id ?? id
  }
  var canCreateInFolderScope: Bool {
    if let folderID = selectedFolderID, state.folders[folderID].flatMap(folderOwner) == nil { return false }
    guard let id = selectedFolderWorkspaceID else { return true }
    return folderWorkspaceGroups.first { $0.id == id }?.canCreate == true
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

struct MobileFolderWorkspace: Identifiable {
  let id: String
  let name: String
  let kind: CompanionExecutionWorkspace.Kind?
  let isLocal: Bool
  var canCreate: Bool { isLocal || kind == .mac || kind == .linux }
}

/// Matches the desktop sidebar: mixed notes/chats, newest activity first, at most 14.
enum MobileFolderRecentItem: Identifiable {
  case note(CompanionNote)
  case conversation(CompanionConversation)
  var id: String { (isNote ? "note-" : "conversation-") + resourceID }
  var isNote: Bool { if case .note = self { return true }; return false }
  var resourceID: String { switch self { case .note(let item): item.id; case .conversation(let item): item.id } }
  var title: String { switch self { case .note(let item): item.title; case .conversation(let item): item.title } }
  var folderID: String? { switch self { case .note(let item): item.folderID; case .conversation(let item): item.folderID } }
  var activityTimestamp: String { switch self { case .note(let item): item.updatedAt; case .conversation(let item): item.updatedAt } }
}
extension CompanionModel {
  var folderRecentItems: [MobileFolderRecentItem] {
    Array((notes.map(MobileFolderRecentItem.note) + conversations.map(MobileFolderRecentItem.conversation)).sorted {
      $0.activityTimestamp == $1.activityTimestamp ? $0.id > $1.id : $0.activityTimestamp > $1.activityTimestamp
    }.prefix(14))
  }
}
