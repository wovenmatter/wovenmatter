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

/// A batch of these edits is one revision-checked note mutation and one history checkpoint.
/// Asset IDs refer to independent library records; removing cards never deletes assets.
public struct CanvasEdit: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable { case add, place, remove, section, removeSection, connect, disconnect, arrange }
  public var action: Action
  public var id: String?
  public var block: NoteBlock?
  public var text: String?
  public var placement: CanvasCardPlacement?
  public var section: CanvasSection?
  public var connection: CanvasConnection?
  public var ids: [String]?
  public var layout: String?
  public init(action: Action, id: String? = nil, block: NoteBlock? = nil, text: String? = nil, placement: CanvasCardPlacement? = nil,
              section: CanvasSection? = nil, connection: CanvasConnection? = nil, ids: [String]? = nil, layout: String? = nil) {
    self.action = action; self.id = id; self.block = block; self.text = text; self.placement = placement
    self.section = section; self.connection = connection; self.ids = ids; self.layout = layout
  }
}

public extension NoteDocument {
  func validateCanvasStructure() throws {
    guard canvasSections != nil || canvasConnections != nil || canvas != nil else { return }
    guard kind == .canvas else { throw NoteDocumentSafetyError.unsupportedFormat }
    let sections = canvasSections ?? [], connections = canvasConnections ?? []
    let blockIDs = Set(blocks.map(\.id)), sectionIDs = Set(sections.map(\.id))
    guard sections.count <= 1000, connections.count <= 20_000,
          sectionIDs.count == sections.count, sectionIDs.isDisjoint(with: blockIDs), sections.allSatisfy(\.isValid),
          Set(connections.map(\.id)).count == connections.count,
          connections.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1024 && $0.from != $0.to && blockIDs.contains($0.from)
            && blockIDs.contains($0.to) && $0.label.utf8.count <= 1024 && CanvasStyle.colors.contains($0.color) }),
          (canvas ?? [:]).values.allSatisfy({ $0.sectionID.map(sectionIDs.contains) ?? true }) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
  }

  mutating func applyCanvasEdit(_ edit: CanvasEdit) throws {
    guard kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    switch edit.action {
    case .add:
      guard edit.block != nil || edit.id?.isEmpty == false else { throw NoteDocumentSafetyError.unsupportedFormat }
      let block = edit.block ?? .richText(NoteRichTextBlock(id: edit.id!, text: edit.text ?? ""))
      guard !blocks.contains(where: { $0.id == block.id }), let placement = edit.placement else {
        throw NoteDocumentSafetyError.unsupportedFormat
      }
      blocks.append(block)
      if canvas == nil { canvas = [:] }
      canvas?[block.id] = placement
    case .place:
      guard let id = edit.id, blocks.contains(where: { $0.id == id }), let placement = edit.placement else {
        throw NoteDocumentSafetyError.unsupportedFormat
      }
      if canvas == nil { canvas = [:] }
      var updated = placement
      // Layout edits cannot silently unlink or retarget an independent asset.
      updated.assetID = canvasPlacement(for: id).assetID
      canvas?[id] = updated
    case .remove:
      guard let id = edit.id, blocks.contains(where: { $0.id == id }) else { throw NoteDocumentSafetyError.unsupportedFormat }
      blocks.removeAll { $0.id == id }; canvas?.removeValue(forKey: id)
      canvasConnections?.removeAll { $0.from == id || $0.to == id }
    case .section:
      guard let section = edit.section, section.isValid else { throw NoteDocumentSafetyError.unsupportedFormat }
      if canvasSections == nil { canvasSections = [] }
      if let index = canvasSections?.firstIndex(where: { $0.id == section.id }), let previous = canvasSections?[index] {
        for block in blocks {
          var placement = canvasPlacement(for: block.id)
          if placement.sectionID == section.id {
            placement.x += section.x - previous.x; placement.y += section.y - previous.y
            canvas?[block.id] = placement
          }
        }
        canvasSections?[index] = section
      } else { canvasSections?.append(section) }
      if let ids = edit.ids {
        guard Set(ids).isSubset(of: Set(blocks.map(\.id))) else { throw NoteDocumentSafetyError.unsupportedFormat }
        if canvas == nil { canvas = [:] }
        for id in ids { var placement = canvasPlacement(for: id); placement.sectionID = section.id; canvas?[id] = placement }
      }
    case .removeSection:
      guard let id = edit.id, canvasSections?.contains(where: { $0.id == id }) == true else { throw NoteDocumentSafetyError.unsupportedFormat }
      canvasSections?.removeAll { $0.id == id }
      for id in Array((canvas ?? [:]).keys) where canvas?[id]?.sectionID == edit.id { canvas?[id]?.sectionID = nil }
    case .connect:
      guard let connection = edit.connection else { throw NoteDocumentSafetyError.unsupportedFormat }
      if canvasConnections == nil { canvasConnections = [] }
      if let index = canvasConnections?.firstIndex(where: { $0.id == connection.id }) { canvasConnections?[index] = connection }
      else { canvasConnections?.append(connection) }
    case .disconnect:
      guard let id = edit.id, canvasConnections?.contains(where: { $0.id == id }) == true else { throw NoteDocumentSafetyError.unsupportedFormat }
      canvasConnections?.removeAll { $0.id == id }
    case .arrange:
      let ids = edit.ids ?? blocks.map(\.id)
      guard Set(ids).count == ids.count, Set(ids).isSubset(of: Set(blocks.map(\.id))),
            ["grid", "row", "column"].contains(edit.layout ?? "grid") else { throw NoteDocumentSafetyError.unsupportedFormat }
      guard !ids.isEmpty else { return }
      let currentPlacements = canvasPlacements
      let placements = ids.compactMap { currentPlacements[$0] }
      let originX = placements.map(\.x).min() ?? 0, originY = placements.map(\.y).min() ?? 0
      let width = (placements.map(\.width).max() ?? 360) + 48, height = (placements.map(\.height).max() ?? 300) + 48
      let columns = edit.layout == "row" ? ids.count : edit.layout == "column" ? 1 : max(1, Int(ceil(sqrt(Double(ids.count)))))
      if canvas == nil { canvas = [:] }
      for (index, id) in ids.enumerated() {
        guard var placement = currentPlacements[id] else { continue }
        placement.x = originX + Double(index % columns) * width; placement.y = originY + Double(index / columns) * height
        canvas?[id] = placement
      }
    }
    try validateEditableShape()
  }
}

/// Transient view metadata, captured at Send; never persisted as shared layout.
public struct CanvasViewportContext: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var zoom: Double
  public var selectedCardIDs: [String]
  public init(x: Double, y: Double, width: Double, height: Double, zoom: Double, selectedCardIDs: [String]) {
    self.x = x; self.y = y; self.width = width; self.height = height; self.zoom = zoom
    self.selectedCardIDs = Array(selectedCardIDs.sorted().prefix(200))
  }
}
