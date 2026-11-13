import Foundation

/// One Mac's window preferences. Each Mac's row has its own ID, so syncing
/// the library never moves one Mac's layout or theme onto another.
public struct SurfaceProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let deviceID: UUID?
  public var theme: String
  public var sidebarStyle: String
  public var singleSidebarSide: String
  public var leftRailVisible: Bool
  public var rightRailVisible: Bool
  public var singleRailVisible: Bool
  public var chatWidthPercent: Double
  public var noteOnLeft: Bool
  public var workspaceMode: String
  public var localCLIAgentOrder: [UUID]?
  public var revision: Int64
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    deviceID: UUID?,
    theme: String,
    sidebarStyle: String,
    singleSidebarSide: String,
    leftRailVisible: Bool,
    rightRailVisible: Bool,
    singleRailVisible: Bool,
    chatWidthPercent: Double,
    noteOnLeft: Bool,
    workspaceMode: String,
    localCLIAgentOrder: [UUID] = [],
    revision: Int64 = 1,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.deviceID = deviceID
    self.theme = theme
    self.sidebarStyle = sidebarStyle
    self.singleSidebarSide = singleSidebarSide
    self.leftRailVisible = leftRailVisible
    self.rightRailVisible = rightRailVisible
    self.singleRailVisible = singleRailVisible
    self.chatWidthPercent = min(80, max(20, chatWidthPercent))
    self.noteOnLeft = noteOnLeft
    self.workspaceMode = workspaceMode
    self.localCLIAgentOrder = localCLIAgentOrder
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func macID(deviceID: UUID) -> String {
    "mac:\(deviceID.uuidString.lowercased())"
  }
}
