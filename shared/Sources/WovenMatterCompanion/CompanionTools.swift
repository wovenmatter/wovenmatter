import Foundation

/// The native caller supplies its synchronized conversation and current tool
/// selection. Selection only narrows access; the central host also checks its
/// persisted user-controlled policy. No device/caller authority comes from CLI
/// arguments or this envelope: the host binds it to the authenticated device.
public struct CompanionToolRequest: Codable, Sendable {
  public var conversationID: String
  public var request: WovenMatterToolRequest
  public var enabledGroups: [WorkspaceToolGroup]
  public init(conversationID: String, request: WovenMatterToolRequest, enabledGroups: [WorkspaceToolGroup]) {
    self.conversationID = conversationID
    self.request = request
    self.enabledGroups = Array(Set(enabledGroups)).sorted { $0.rawValue < $1.rawValue }
  }
}
