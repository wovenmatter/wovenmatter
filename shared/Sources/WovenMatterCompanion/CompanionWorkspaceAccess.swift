import Foundation

/// Central-library policy for direct execution access. This does not restrict
/// shared-library visibility and does not grant history-publication authority.
public struct CompanionWorkspaceAccessPolicy: Codable, Equatable, Sendable {
  public var deviceID: String
  public var workspaceID: String
  public var enabled: Bool
  public init(deviceID: String, workspaceID: String, enabled: Bool) {
    self.deviceID = deviceID; self.workspaceID = workspaceID; self.enabled = enabled
  }
}
