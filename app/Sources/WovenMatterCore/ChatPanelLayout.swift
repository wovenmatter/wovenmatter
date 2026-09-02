import Foundation

public struct DashboardChatPanelID: Hashable, Codable, Sendable, Identifiable {
  public static let primary = DashboardChatPanelID(rawValue: "primary")

  public let rawValue: String

  public var id: String { rawValue }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct DashboardChatPanel: Equatable, Sendable, Identifiable {
  public let id: DashboardChatPanelID
  public var conversationID: String?

  public init(id: DashboardChatPanelID, conversationID: String?) {
    self.id = id
    self.conversationID = conversationID
  }
}

public struct DashboardChatPanelFrame: Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  var minX: Double { x }
  var maxX: Double { x + width }
  var midX: Double { x + width / 2 }
  var minY: Double { y }
  var maxY: Double { y + height }
  var midY: Double { y + height / 2 }
}

public enum DashboardChatPanelDirection: Sendable {
  case left
  case right
  case up
  case down
}

public struct DashboardChatPanelFocusRequest: Equatable, Sendable {
  public let panelID: DashboardChatPanelID
  public let generation: Int

  public init(panelID: DashboardChatPanelID, generation: Int) {
    self.panelID = panelID
    self.generation = generation
  }
}

public enum DashboardChatPanelMetrics {
  public static let dividerThickness = 0.5
  public static let maximumPanelCount = 5
}

/// Window-scoped chat layout state. It owns presentation only and deliberately
/// has no chat lifecycle dependency, so removing a panel cannot stop, archive,
/// close, or delete the conversation displayed in it.
public struct DashboardChatPanelState: Equatable, Sendable {
  public private(set) var primary: DashboardChatPanel
  public private(set) var auxiliaryRows: [[DashboardChatPanel]]
  public private(set) var activePanelID: DashboardChatPanelID
  public private(set) var assetPresented: Bool
  public private(set) var focusRequest: DashboardChatPanelFocusRequest?

  private var focusGeneration: Int

  public init(primaryConversationID: String? = nil) {
    primary = DashboardChatPanel(
      id: .primary,
      conversationID: primaryConversationID
    )
    auxiliaryRows = []
    activePanelID = .primary
    assetPresented = false
    focusRequest = nil
    focusGeneration = 0
  }

  public var panels: [DashboardChatPanel] {
    [primary] + auxiliaryRows.flatMap { $0 }
  }

  public var panelCount: Int { panels.count }

  public var hasAuxiliaryPanels: Bool { !auxiliaryRows.isEmpty }

  public var activeConversationID: String? {
    panel(id: activePanelID)?.conversationID
  }

  public func panel(id: DashboardChatPanelID) -> DashboardChatPanel? {
    panels.first { $0.id == id }
  }

  public func canClosePanel(_ panelID: DashboardChatPanelID) -> Bool {
    panelID != .primary && panel(id: panelID) != nil
  }

  public func canAddPanel(from panelID: DashboardChatPanelID) -> Bool {
    if auxiliaryRows.isEmpty {
      return panelID == .primary
    }
    guard panelID != .primary,
          panelCount < DashboardChatPanelMetrics.maximumPanelCount,
          let location = auxiliaryLocation(of: panelID) else {
      return false
    }
    return auxiliaryRows[location.row].count == 1
  }

  @discardableResult
  public mutating func addPanel(
    from panelID: DashboardChatPanelID,
    newPanelID: DashboardChatPanelID
  ) -> Bool {
    guard newPanelID != .primary,
          panel(id: newPanelID) == nil,
          canAddPanel(from: panelID) else {
      return false
    }

    assetPresented = false
    let inheritedConversationID = panel(id: panelID)?.conversationID
    let panel = DashboardChatPanel(
      id: newPanelID,
      conversationID: inheritedConversationID
    )

    if auxiliaryRows.isEmpty {
      auxiliaryRows = [[panel]]
    } else if auxiliaryRows.count == 1 {
      // The first auxiliary remains A in the upper row and the newcomer is B.
      auxiliaryRows.append([panel])
    } else if let location = auxiliaryLocation(of: panelID) {
      // A divided row preserves its invoking panel at the leading edge.
      auxiliaryRows[location.row].append(panel)
    } else {
      return false
    }

    activePanelID = newPanelID
    requestComposerFocus(for: newPanelID)
    return true
  }

  @discardableResult
  public mutating func closePanel(_ panelID: DashboardChatPanelID) -> Bool {
    guard let location = auxiliaryLocation(of: panelID) else { return false }

    let wasActive = activePanelID == panelID
    auxiliaryRows[location.row].remove(at: location.column)

    if auxiliaryRows[location.row].isEmpty {
      auxiliaryRows.remove(at: location.row)
    }

    if wasActive {
      if auxiliaryRows.indices.contains(location.row) {
        let row = auxiliaryRows[location.row]
        activePanelID = row[min(location.column, row.count - 1)].id
      } else if let lastRow = auxiliaryRows.last {
        activePanelID = lastRow[min(location.column, lastRow.count - 1)].id
      } else {
        activePanelID = .primary
      }
    }
    return true
  }

  @discardableResult
  public mutating func activatePanel(_ panelID: DashboardChatPanelID) -> Bool {
    guard panel(id: panelID) != nil else { return false }
    activePanelID = panelID
    return true
  }

  @discardableResult
  public mutating func replaceActiveConversation(with conversationID: String?) -> Bool {
    setConversation(conversationID, in: activePanelID)
  }

  @discardableResult
  public mutating func setConversation(
    _ conversationID: String?,
    in panelID: DashboardChatPanelID
  ) -> Bool {
    if panelID == .primary {
      primary.conversationID = conversationID
      return true
    }
    guard let location = auxiliaryLocation(of: panelID) else { return false }
    auxiliaryRows[location.row][location.column].conversationID = conversationID
    return true
  }

  public mutating func presentAsset() {
    auxiliaryRows.removeAll()
    activePanelID = .primary
    assetPresented = true
  }

  public mutating func dismissAsset() {
    assetPresented = false
  }

  @discardableResult
  public mutating func navigate(
    _ direction: DashboardChatPanelDirection
  ) -> DashboardChatPanelID? {
    guard hasAuxiliaryPanels,
          !assetPresented,
          let destination = neighbor(from: activePanelID, direction: direction) else {
      return nil
    }
    activePanelID = destination
    requestComposerFocus(for: destination)
    return destination
  }

  public func normalizedFrames() -> [DashboardChatPanelID: DashboardChatPanelFrame] {
    guard hasAuxiliaryPanels else {
      return [.primary: DashboardChatPanelFrame(x: 0, y: 0, width: 1, height: 1)]
    }

    var result: [DashboardChatPanelID: DashboardChatPanelFrame] = [
      .primary: DashboardChatPanelFrame(x: 0, y: 0, width: 0.5, height: 1)
    ]
    let rowHeight = 1 / Double(auxiliaryRows.count)
    for (rowIndex, row) in auxiliaryRows.enumerated() {
      let columnWidth = 0.5 / Double(row.count)
      for (columnIndex, panel) in row.enumerated() {
        result[panel.id] = DashboardChatPanelFrame(
          x: 0.5 + Double(columnIndex) * columnWidth,
          y: Double(rowIndex) * rowHeight,
          width: columnWidth,
          height: rowHeight
        )
      }
    }
    return result
  }

  public func neighbor(
    from panelID: DashboardChatPanelID,
    direction: DashboardChatPanelDirection
  ) -> DashboardChatPanelID? {
    let frames = normalizedFrames()
    guard let source = frames[panelID] else { return nil }
    let order = Dictionary(uniqueKeysWithValues:
      panels.enumerated().map { ($0.element.id, $0.offset) }
    )
    let epsilon = 0.000_001

    let candidates = panels.compactMap { panel -> (
      id: DashboardChatPanelID,
      gap: Double,
      perpendicularDistance: Double,
      order: Int
    )? in
      guard panel.id != panelID, let frame = frames[panel.id] else { return nil }
      let gap: Double
      let perpendicularDistance: Double
      switch direction {
      case .left:
        guard frame.maxX <= source.minX + epsilon else { return nil }
        gap = max(0, source.minX - frame.maxX)
        perpendicularDistance = abs(source.midY - frame.midY)
      case .right:
        guard frame.minX >= source.maxX - epsilon else { return nil }
        gap = max(0, frame.minX - source.maxX)
        perpendicularDistance = abs(source.midY - frame.midY)
      case .up:
        guard frame.maxY <= source.minY + epsilon else { return nil }
        gap = max(0, source.minY - frame.maxY)
        perpendicularDistance = abs(source.midX - frame.midX)
      case .down:
        guard frame.minY >= source.maxY - epsilon else { return nil }
        gap = max(0, frame.minY - source.maxY)
        perpendicularDistance = abs(source.midX - frame.midX)
      }
      return (panel.id, gap, perpendicularDistance, order[panel.id, default: 0])
    }

    return candidates.min {
      if abs($0.gap - $1.gap) > epsilon { return $0.gap < $1.gap }
      if abs($0.perpendicularDistance - $1.perpendicularDistance) > epsilon {
        return $0.perpendicularDistance < $1.perpendicularDistance
      }
      return $0.order < $1.order
    }?.id
  }

  private func auxiliaryLocation(
    of panelID: DashboardChatPanelID
  ) -> (row: Int, column: Int)? {
    for (rowIndex, row) in auxiliaryRows.enumerated() {
      if let columnIndex = row.firstIndex(where: { $0.id == panelID }) {
        return (rowIndex, columnIndex)
      }
    }
    return nil
  }

  private mutating func requestComposerFocus(for panelID: DashboardChatPanelID) {
    focusGeneration += 1
    focusRequest = DashboardChatPanelFocusRequest(
      panelID: panelID,
      generation: focusGeneration
    )
  }
}
