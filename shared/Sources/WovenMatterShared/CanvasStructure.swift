import Foundation

public enum CanvasStyle {
  public static let colors = ["neutral", "green", "blue", "purple", "orange", "pink"]
}

public struct CanvasSection: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var color: String
  public init(id: String = UUID().uuidString.lowercased(), title: String, x: Double, y: Double,
              width: Double = 1000, height: Double = 700, color: String = "green") {
    self.id = id; self.title = title; self.x = x; self.y = y
    self.width = width; self.height = height; self.color = color
  }
  public var isValid: Bool {
    !id.isEmpty && id.utf8.count <= 1024 && title.utf8.count <= 1024 && CanvasStyle.colors.contains(color)
      && x.isFinite && y.isFinite && abs(x) <= 1_000_000_000 && abs(y) <= 1_000_000_000
      && width.isFinite && height.isFinite && (200...1_000_000).contains(width) && (120...1_000_000).contains(height)
  }
}

public struct CanvasConnection: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var from: String
  public var to: String
  public var label: String
  public var color: String
  public init(id: String = UUID().uuidString.lowercased(), from: String, to: String,
              label: String = "", color: String = "neutral") {
    self.id = id; self.from = from; self.to = to; self.label = label; self.color = color
  }
}

public extension NoteDocument {
  func validateCanvasStructure() throws {
    guard canvasSections != nil || canvasConnections != nil || canvas != nil || boardPurpose != nil || boardItems != nil else { return }
    guard kind == .canvas else { throw NoteDocumentSafetyError.unsupportedFormat }
    let sections = canvasSections ?? [], connections = canvasConnections ?? []
    let blockIDs = Set(blocks.map(\.id)), sectionIDs = Set(sections.map(\.id))
    guard (boardPurpose?.utf8.count ?? 0) <= Self.maximumBoardPurposeBytes,
          (boardItems ?? [:]).allSatisfy({ blockIDs.contains($0.key) && $0.value.isValid }) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
    guard sections.count <= 1000, connections.count <= 20_000,
          sectionIDs.count == sections.count, sectionIDs.isDisjoint(with: blockIDs), sections.allSatisfy(\.isValid),
          Set(connections.map(\.id)).count == connections.count,
          connections.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1024 && $0.from != $0.to && blockIDs.contains($0.from)
            && blockIDs.contains($0.to) && $0.label.utf8.count <= 1024 && CanvasStyle.colors.contains($0.color) }),
          (canvas ?? [:]).values.allSatisfy({ $0.sectionID.map(sectionIDs.contains) ?? true }) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
  }
}

/// The Page selection captured at Send. Transient view metadata, never persisted.
public struct CanvasViewportContext: Codable, Equatable, Sendable {
  public var selectedCardIDs: [String]
  public init(selectedCardIDs: [String]) {
    self.selectedCardIDs = Array(selectedCardIDs.sorted().prefix(200))
  }
}
