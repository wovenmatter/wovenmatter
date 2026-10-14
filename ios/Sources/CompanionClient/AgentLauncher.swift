import Foundation
import WovenMatterCompanion

public struct CompanionAgentLauncher: Identifiable, Equatable, Sendable {
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
  public var isLocalMac: Bool { groupID == "central" }

  public init(workspaceID: String, workspaceName: String, providerID: String, name: String, runtimeKind: String, isAvailable: Bool = true, groupID: String? = nil, conversationRoutes: [String: Set<String>] = [:]) {
    self.groupID = groupID ?? workspaceID; self.conversationRoutes = conversationRoutes
    self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.providerID = providerID
    self.name = name; self.runtimeKind = runtimeKind; self.isAvailable = isAvailable
  }

  /// Ownership is authoritative: identical harness names on different devices are different agents.
  public func latestConversation(in conversations: [CompanionConversation], owner: (String) -> String) -> CompanionConversation? {
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

  public static func list(deviceName: String, centralOnline: Bool, providers: [CompanionProvider],
                          workspaces: [CompanionExecutionWorkspace], workspaceProviders: [String: [CompanionProvider]],
                          reachable: [String: Bool], knownAgentIDs: Set<String> = []) -> [Self] {
    func known(_ provider: CompanionProvider, workspace: String) -> Bool {
      (provider.available && provider.canStart) || knownAgentIDs.contains(workspace + ":" + provider.id)
    }
    let workspaces = workspaces.filter { !$0.deleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let central = workspaces.first { $0.kind == .mac && $0.capabilities.contains("history.central.v1") }
    var result: [Self] = [.init(workspaceID: "local", workspaceName: deviceName, providerID: "pi-durable-device", name: "Pi Durable", runtimeKind: "pi")]
    var representedDirectAgents = Set<String>()
    for provider in providers where known(provider, workspace: "central") {
      let parts = provider.id.split(separator: ":", omittingEmptySubsequences: false)
      let remoteID = parts.count == 3 && parts[0] == "remote" ? UUID(uuidString: String(parts[1]))?.uuidString.lowercased() : nil
      let workspace = remoteID.flatMap { id in workspaces.first { $0.id == id } } ?? (remoteID == nil ? central : nil)
      let group = remoteID ?? "central"
      let name = workspace?.name ?? (group == "central" ? "Mac" : provider.routeName)
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

/// The directory, rather than available agents, determines which workspaces exist.
public struct CompanionAgentGroup: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var workspace: CompanionExecutionWorkspace?
  public var agents: [CompanionAgentLauncher]

  public static func list(agents: [CompanionAgentLauncher], workspaces: [CompanionExecutionWorkspace]) -> [Self] {
    var groups: [Self] = []
    for agent in agents {
      if let index = groups.firstIndex(where: { $0.id == agent.groupID }) { groups[index].agents.append(agent) }
      else { groups.append(.init(id: agent.groupID, name: agent.workspaceName, agents: [agent])) }
    }
    for workspace in workspaces where !workspace.deleted {
      let id = workspace.kind == .mac && workspace.capabilities.contains("history.central.v1") ? "central" : workspace.id
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
public struct CompanionAgentCatalog: Codable, Equatable, Sendable {
  public var libraryID: String
  public var providers: [CompanionProvider]
  public var workspaceProviders: [String: [CompanionProvider]]
  public var knownAgentIDs: Set<String>
  public init(libraryID: String, providers: [CompanionProvider], workspaceProviders: [String: [CompanionProvider]], knownAgentIDs: Set<String>) {
    self.libraryID = libraryID; self.providers = providers; self.workspaceProviders = workspaceProviders; self.knownAgentIDs = knownAgentIDs
  }
}
