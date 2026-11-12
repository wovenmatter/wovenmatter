import Foundation

/// Layout belongs to the document; each card's content remains an ordinary note
/// block, so existing revision-checked agent edits and history keep working.
public struct CanvasCardPlacement: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  /// A library note ID, never a copied document or a machine-local path.
  public var assetID: String?
  public var title: String?
  public var color: String?
  public var sectionID: String?

  public init(x: Double, y: Double, width: Double = 360, height: Double = 300, assetID: String? = nil) {
    self.x = x; self.y = y; self.width = width; self.height = height; self.assetID = assetID
  }

  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && abs(x) <= 1_000_000_000 && abs(y) <= 1_000_000_000
      && (200...4000).contains(width) && (120...4000).contains(height)
      && (title?.utf8.count ?? 0) <= 1024
      && (color.map { CanvasStyle.colors.contains($0) } ?? true)
      && (assetID.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? true)
  }
}

public extension NoteDocument {
  /// The stored placement, or an empty one. A Page keeps placements only for an
  /// original's label and embed height, and for layout kept from an older Board.
  func canvasPlacement(for blockID: String) -> CanvasCardPlacement {
    canvas?[blockID] ?? CanvasCardPlacement(x: 0, y: 0)
  }
}
