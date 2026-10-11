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
  public var isLocalMac: Bool { workspaceID == "central" && !providerID.hasPrefix("remote:") && !providerID.hasPrefix("buzz:") && !providerID.hasPrefix("gateway:") }

  public init(workspaceID: String, workspaceName: String, providerID: String, name: String, runtimeKind: String, isAvailable: Bool = true) {
    self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.providerID = providerID
    self.name = name; self.runtimeKind = runtimeKind; self.isAvailable = isAvailable
  }

  /// Ownership is authoritative: identical harness names on different devices are different agents.
  public func latestConversation(in conversations: [CompanionConversation], owner: (String) -> String) -> CompanionConversation? {
    conversations.filter { owner($0.id) == workspaceID && $0.providerID == providerID }
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
    var result: [Self] = [.init(workspaceID: "local", workspaceName: deviceName, providerID: "pi-durable-device", name: "Pi Durable", runtimeKind: "pi")]
    var representedDirectAgents = Set<String>()
    for provider in providers where known(provider, workspace: "central") {
      let parts = provider.id.split(separator: ":", omittingEmptySubsequences: false)
      if parts.count == 3, parts[0] == "remote", let id = UUID(uuidString: String(parts[1]))?.uuidString.lowercased(),
         workspaces.contains(where: { $0.id == id }),
         let direct = workspaceProviders[id]?.first(where: { known($0, workspace: id) && $0.runtimeKind == provider.runtimeKind }) {
        let directAvailable = reachable[id] == true && direct.available && direct.canStart
        // Prefer direct execution, but keep the central route when it is the only reachable route.
        if directAvailable || !centralOnline || !provider.available || !provider.canStart { continue }
        representedDirectAgents.insert(id + ":" + direct.id)
      }
      result.append(.init(workspaceID: "central", workspaceName: provider.routeName.isEmpty ? "Central Mac" : provider.routeName,
        providerID: provider.id, name: provider.displayName, runtimeKind: provider.runtimeKind,
        isAvailable: centralOnline && provider.available && provider.canStart))
    }
    for workspace in workspaces {
      for provider in workspaceProviders[workspace.id] ?? [] where known(provider, workspace: workspace.id) {
        guard !representedDirectAgents.contains(workspace.id + ":" + provider.id) else { continue }
        result.append(.init(workspaceID: workspace.id, workspaceName: workspace.name, providerID: provider.id,
          name: provider.displayName, runtimeKind: provider.runtimeKind,
          isAvailable: reachable[workspace.id] == true && provider.available && provider.canStart))
      }
    }
    return result
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
