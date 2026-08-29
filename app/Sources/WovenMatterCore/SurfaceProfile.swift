import Foundation

public enum DashboardSurface: String, Codable, CaseIterable, Sendable {
  case web = "server_web"
  case mac = "mac_native"

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let value = DashboardSurface(persistedValue: try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported dashboard surface"
      )
    }
    self = value
  }

  public init?(persistedValue: String) {
    switch persistedValue {
    case "server_web", "web": self = .web
    case "mac_native", "mac": self = .mac
    default: return nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A surface-scoped preference projection. Web and Mac rows intentionally use
/// different IDs so synchronizing one surface never activates its layout or
/// theme on the other.
public struct SurfaceProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let userID: String
  public let surface: DashboardSurface
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
    userID: String,
    surface: DashboardSurface,
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
    self.userID = userID
    self.surface = surface
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
