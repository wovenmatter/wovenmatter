import Foundation
import WovenMatterShared

public struct LaunchableAgent: Identifiable, Equatable, Sendable {
  public var workspaceID: String
  public var workspaceName: String
  public var providerID: String
  public var name: String
  public var runtimeKind: String
  public var isAvailable: Bool
  public var id: String { workspaceID + ":" + providerID }
  /// Display ownership stays stable when the usable transport route changes.
  public var groupID: String
  public var conversationRoutes: [String: Set<String>]

  public init(workspaceID: String, workspaceName: String, providerID: String, name: String, runtimeKind: String, isAvailable: Bool = true, groupID: String? = nil, conversationRoutes: [String: Set<String>] = [:]) {
    self.groupID = groupID ?? workspaceID; self.conversationRoutes = conversationRoutes
    self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.providerID = providerID
    self.name = name; self.runtimeKind = runtimeKind; self.isAvailable = isAvailable
  }

  /// Ownership is authoritative: identical harness names on different devices are different agents.
  public func latestConversation(in conversations: [LibraryConversation], owner: (String) -> String) -> LibraryConversation? {
    conversations.filter { conversation in
      guard let provider = conversation.providerID else { return false }
      let workspace = owner(conversation.id)
      return (workspace == workspaceID && provider == providerID) || conversationRoutes[workspace]?.contains(provider) == true
    }
      .max { left, right in
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date {
          formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          if let result = formatter.date(from: value) { return result }
          formatter.formatOptions = [.withInternetDateTime]
          return formatter.date(from: value) ?? .distantPast
        }
        let lhs = date(left.updatedAt), rhs = date(right.updatedAt)
        return lhs == rhs ? left.id < right.id : lhs < rhs
      }
  }

  /// `providers` is the central list: the agents of the library host this
  /// phone syncs with (`centralWorkspaceID`, or `centralName` while its
  /// registry row is unknown). Every other workspace lists its own agents.
  public static func list(deviceName: String, centralOnline: Bool, providers: [HarnessCapabilities],
                          workspaces: [ExecutionWorkspace], workspaceProviders: [String: [HarnessCapabilities]],
                          reachable: [String: Bool], knownAgentIDs: Set<String> = [],
                          centralWorkspaceID: String? = nil, centralName: String? = nil) -> [Self] {
    func known(_ provider: HarnessCapabilities, workspace: String) -> Bool {
      (provider.available && provider.canStart) || knownAgentIDs.contains(workspace + ":" + provider.id)
    }
    let workspaces = workspaces.filter { !$0.deleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let central = ExecutionWorkspace.liveCentralMac(in: workspaces, id: centralWorkspaceID)
    var result: [Self] = [.init(workspaceID: "local", workspaceName: deviceName, providerID: "pi-durable-device", name: "Quick Chat", runtimeKind: "default_agent")]
    var representedDirectAgents = Set<String>()
    for provider in providers where known(provider, workspace: "central") {
      let parts = provider.id.split(separator: ":", omittingEmptySubsequences: false)
      let remoteID = parts.count == 3 && parts[0] == "remote" ? UUID(uuidString: String(parts[1]))?.uuidString.lowercased() : nil
      let workspace = remoteID.flatMap { id in workspaces.first { $0.id == id } } ?? (remoteID == nil ? central : nil)
      let group = remoteID ?? "central"
      let name = workspace?.name ?? (group == "central" ? centralName ?? "Mac" : provider.routeName)
      let direct = workspace.flatMap { workspace in
        workspaceProviders[workspace.id]?.first { candidate in
          known(candidate, workspace: workspace.id) &&
            (remoteID == nil ? candidate.id == provider.id : candidate.runtimeKind == provider.runtimeKind)
        }
      }
      var routes: [String: Set<String>] = ["central": [provider.id]]
      if let workspace, let direct {
        routes[workspace.id] = [direct.id]
        representedDirectAgents.insert(workspace.id + ":" + direct.id)
        let directAvailable = reachable[workspace.id] == true && direct.available && direct.canStart
        let centralAvailable = centralOnline && provider.available && provider.canStart
        // Prefer the canonical Mac route for its own agents and direct Linux
        // execution when reachable. Either route still represents one agent.
        if (remoteID != nil && directAvailable) || !centralAvailable {
          result.append(.init(workspaceID: workspace.id, workspaceName: name, providerID: direct.id,
            name: provider.displayName, runtimeKind: direct.runtimeKind, isAvailable: directAvailable,
            groupID: group, conversationRoutes: routes))
          continue
        }
      }
      result.append(.init(workspaceID: "central", workspaceName: name,
        providerID: provider.id, name: provider.displayName, runtimeKind: provider.runtimeKind,
        isAvailable: centralOnline && provider.available && provider.canStart, groupID: group, conversationRoutes: routes))
    }
    for workspace in workspaces {
      for provider in workspaceProviders[workspace.id] ?? [] where known(provider, workspace: workspace.id) {
        guard !representedDirectAgents.contains(workspace.id + ":" + provider.id) else { continue }
        result.append(.init(workspaceID: workspace.id, workspaceName: workspace.name, providerID: provider.id,
          name: provider.displayName, runtimeKind: provider.runtimeKind,
          isAvailable: reachable[workspace.id] == true && provider.available && provider.canStart,
          groupID: workspace.id == central?.id ? "central" : workspace.id))
      }
    }
    return result
  }
}

extension ExecutionWorkspace {
  /// A live Mac workspace that serves central history. A copied snapshot owner
  /// (`retainedHistory`) keeps the capability for its history but is not live.
  /// Every Mac that hosts a library advertises it, so several can be live.
  public var isLiveCentralMac: Bool {
    kind == .mac && capabilities.contains("history.central.v1") && !deleted && retainedHistory != true
  }
  /// The library host's workspace: the live central Mac with `id`, the
  /// library host the phone syncs with. Without a known host (an older
  /// pairing), the first live central Mac.
  public static func liveCentralMac(in workspaces: [Self], id: String?) -> Self? {
    guard let id else { return workspaces.first(where: \.isLiveCentralMac) }
    return workspaces.first { $0.id == id && $0.isLiveCentralMac }
  }
}

/// The directory, rather than available agents, determines which workspaces exist.
public struct AgentGroup: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var workspace: ExecutionWorkspace?
  public var agents: [LaunchableAgent]

  /// Quick Chat first, then the library host (`centralWorkspaceID`), the
  /// other Macs and the Linux workspaces, each by name.
  public static func list(agents: [LaunchableAgent], workspaces: [ExecutionWorkspace],
                          centralWorkspaceID: String? = nil) -> [Self] {
    let central = ExecutionWorkspace.liveCentralMac(in: workspaces, id: centralWorkspaceID)
    var groups: [Self] = []
    for agent in agents {
      if let index = groups.firstIndex(where: { $0.id == agent.groupID }) { groups[index].agents.append(agent) }
      else { groups.append(.init(id: agent.groupID, name: agent.workspaceName, agents: [agent])) }
    }
    // A copied snapshot owner is history, not a workspace to launch in; it must not rename the central group.
    for workspace in workspaces where !workspace.deleted && workspace.retainedHistory != true {
      let id = workspace.id == central?.id ? "central" : workspace.id
      if let index = groups.firstIndex(where: { $0.id == id }) {
        groups[index].workspace = workspace; groups[index].name = workspace.name
      } else { groups.append(.init(id: id, name: workspace.name, workspace: workspace, agents: [])) }
    }
    func rank(_ group: Self) -> Int {
      if group.id == "local" { return 0 }
      if group.id == "central" { return 1 }
      return group.workspace?.kind == .mac ? 2 : 3
    }
    return groups.sorted {
      rank($0) == rank($1) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : rank($0) < rank($1)
    }
  }
}

/// Non-secret discovery metadata; loading it never restores a live connection.
public struct AgentCatalog: Codable, Equatable, Sendable {
  public var libraryID: String
  public var providers: [HarnessCapabilities]
  public var workspaceProviders: [String: [HarnessCapabilities]]
  public var knownAgentIDs: Set<String>
  public init(libraryID: String, providers: [HarnessCapabilities], workspaceProviders: [String: [HarnessCapabilities]], knownAgentIDs: Set<String>) {
    self.libraryID = libraryID; self.providers = providers; self.workspaceProviders = workspaceProviders; self.knownAgentIDs = knownAgentIDs
  }
}
