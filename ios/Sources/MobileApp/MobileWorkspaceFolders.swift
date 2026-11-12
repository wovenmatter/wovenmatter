import Foundation
import LibraryClient
import WovenMatterShared

extension MobileModel {
  /// Groups content by the workspace that owns it. Folder bindings and registry
  /// rows name the same device with or without a `device:`/`remote:` prefix, and
  /// the central Mac's folders name the owner its registry row lists as
  /// `folderOwnerID`; this is display grouping only and never decides execution ownership.
  func canonicalWorkspaceID(_ id: String) -> String {
    if id == "local" || id == "device" { return Self.displayWorkspaceID(deviceWorkspaceID) }
    if id == "central", let central = centralExecutionWorkspace { return Self.displayWorkspaceID(central.id) }
    return ExecutionWorkspace.displayOwner(of: id, in: executionWorkspaces) ?? Self.displayWorkspaceID(id)
  }
  static func displayWorkspaceID(_ value: String) -> String { ExecutionWorkspace.displayID(value) }
  func folderOwner(_ folder: LibraryFolder) -> String? { folder.execution.map { canonicalWorkspaceID($0.workspaceID) } }
  /// Notes belong to their folder's workspace; unfiled notes appear in All Workspaces.
  func noteOwner(_ note: LibraryNote) -> String? {
    note.folderID.flatMap { state.folders[$0] }.flatMap(folderOwner)
  }
  func conversationOwner(_ conversation: LibraryConversation) -> String? {
    if executionRecords[conversation.id] != nil { return canonicalWorkspaceID(deviceWorkspaceID) }
    if let owner = conversation.workspaceID ?? conversationWorkspaceIDs[conversation.id] { return canonicalWorkspaceID(owner) }
    if let folder = conversation.folderID.flatMap({ state.folders[$0] }), let owner = folderOwner(folder) { return owner }
    if let provider = conversation.providerID {
      let parts = provider.split(separator: ":")
      if parts.count == 3, parts[0] == "remote", UUID(uuidString: String(parts[1])) != nil { return canonicalWorkspaceID(String(parts[1])) }
      if providers.contains(where: { $0.id == provider }) {
        return centralExecutionWorkspace.map { canonicalWorkspaceID($0.id) }
      }
    }
    return nil
  }
  /// The iPhone lists a Mac or Linux workspace, with its agents and folders,
  /// only while it is paired and reachable now: its own connection answered,
  /// or it is the library host this phone is synced with. A registry row or
  /// saved agent catalog alone never lists it. Nothing stored is removed, and
  /// the next refresh that reaches it lists it again. Settings → Workspaces
  /// keeps every saved workspace with its connection state.
  func workspaceIsActive(_ workspace: ExecutionWorkspace) -> Bool {
    guard !workspace.deleted, workspace.retainedHistory != true, workspace.kind != .ios else { return false }
    if workspaceReachable[workspace.id] == true { return true }
    return online && centralExecutionWorkspace?.id == workspace.id
  }
  /// Quick Chat is always listed. A copied snapshot owner (`retainedHistory`)
  /// never is, even when its copied endpoint answers; its chats stay readable
  /// in All Workspaces and Recents. A workspace's group is listed while that
  /// workspace is active or any of its agents can start now (a Linux
  /// workspace reached through the central Mac).
  func agentGroupIsActive(_ group: AgentGroup) -> Bool {
    if group.id == "local" { return true }
    if executionWorkspaces.contains(where: { $0.id == group.id && ($0.retainedHistory == true || $0.deleted) }) { return false }
    if let workspace = group.workspace, workspaceIsActive(workspace) { return true }
    return group.agents.contains(where: \.isAvailable)
  }
  /// The local workspace, the active Mac and Linux workspaces, and other
  /// Apple devices' synced Quick Chat history (never a connection). Content
  /// whose owner is not listed stays in All Workspaces and Recents.
  var folderWorkspaceGroups: [MobileFolderWorkspace] {
    let localID = canonicalWorkspaceID(deviceWorkspaceID)
    var result = [MobileFolderWorkspace(id: localID, name: deviceWorkspaceName, kind: .ios, isLocal: true)]
    let active = Set(launcherGroups.compactMap { $0.workspace.map { canonicalWorkspaceID($0.id) } })
    for workspace in executionWorkspaces where !workspace.deleted {
      let id = canonicalWorkspaceID(workspace.id)
      guard workspace.retainedHistory != true, workspace.kind == .ios || active.contains(id),
            !result.contains(where: { $0.id == id }) else { continue }
      result.append(.init(id: id, name: workspace.name, kind: workspace.kind, isLocal: false))
    }
    return result
  }
  var hasUnassignedContent: Bool {
    folders.contains { folderOwner($0) == nil } || notes.contains { noteOwner($0) == nil } || conversations.contains { conversationOwner($0) == nil }
  }
  func folderAgents(in workspace: MobileFolderWorkspace) -> [LaunchableAgent] {
    guard workspace.isLocal || workspace.kind != .ios else { return [] }
    return launcherAgents.filter { canonicalWorkspaceID($0.workspaceID) == workspace.id }
  }
  var chatLauncherGroups: [AgentGroup] {
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
  var folderWorkspaces: [ExecutionWorkspace] { executionWorkspaces.filter { $0.kind == .mac || $0.kind == .linux } }
  func routeOwnsFolder(workspaceID: String, folderID: String?) -> Bool {
    guard let folderID, let folder = state.folders[folderID], let owner = folderOwner(folder) else { return true }
    return owner == canonicalWorkspaceID(workspaceID)
  }
  var selectedFolderScopeTitle: String {
    if let id = selectedFolderID { return state.folders[id]?.name ?? "Folder" }
    if selectedFolderWorkspaceID == "unassigned" { return "Unassigned items" }
    guard let owner = selectedFolderWorkspaceID else { return "All Workspaces" }
    let name = folderWorkspaceGroups.first { $0.id == owner }?.name
      ?? executionWorkspaces.first { canonicalWorkspaceID($0.id) == owner }?.name ?? "Workspace"
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
  /// Folders bound to another workspace's files are created on that Mac or Linux
  /// device. Starting a chat checks only that the agent belongs to the folder's workspace.
  func prepareExecutionFolder(_ folderID: String?, workspaceID: String) async throws {
    guard routeOwnsFolder(workspaceID: workspaceID, folderID: folderID) else {
      throw DeviceExecutionError.unavailable("Choose an agent in this folder’s owning workspace.")
    }
  }
}

struct MobileFolderWorkspace: Identifiable {
  let id: String
  let name: String
  let kind: ExecutionWorkspace.Kind?
  let isLocal: Bool
  var canCreate: Bool { isLocal || kind == .mac || kind == .linux }
  /// New folders on this device; other workspaces create folders where their files live.
  var canCreateFolder: Bool { isLocal }
}

/// Matches the desktop sidebar: mixed notes/chats, newest activity first, at most 14.
enum MobileFolderRecentItem: Identifiable {
  case note(LibraryNote)
  case conversation(LibraryConversation)
  var id: String { (isNote ? "note-" : "conversation-") + resourceID }
  var isNote: Bool { if case .note = self { return true }; return false }
  var resourceID: String { switch self { case .note(let item): item.id; case .conversation(let item): item.id } }
  var title: String { switch self { case .note(let item): item.title; case .conversation(let item): item.title } }
  var folderID: String? { switch self { case .note(let item): item.folderID; case .conversation(let item): item.folderID } }
  var activityTimestamp: String { switch self { case .note(let item): item.updatedAt; case .conversation(let item): item.updatedAt } }
}
extension MobileModel {
  var folderRecentItems: [MobileFolderRecentItem] {
    let formatter = ISO8601DateFormatter()
    func date(_ timestamp: String) -> Date {
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let value = formatter.date(from: timestamp) { return value }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: timestamp) ?? .distantPast
    }
    let items = (notes.map(MobileFolderRecentItem.note) + conversations.map(MobileFolderRecentItem.conversation)).map { ($0, date($0.activityTimestamp)) }
    return Array(items.sorted {
      $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 > $1.1
    }.prefix(14).map(\.0))
  }
}
