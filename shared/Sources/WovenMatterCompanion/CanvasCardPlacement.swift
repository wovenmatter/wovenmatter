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

  public static func automatic(index: Int) -> Self {
    Self(x: 24 + Double(index % 5) * 392, y: 24 + Double(index / 5) * 332)
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
  static let maximumCanvasCards = 10_000

  var canvasPlacements: [String: CanvasCardPlacement] {
    Dictionary(uniqueKeysWithValues: blocks.enumerated().map { index, block in
      (block.id, canvas?[block.id] ?? .automatic(index: index))
    })
  }

  func canvasPlacement(for blockID: String) -> CanvasCardPlacement {
    canvas?[blockID] ?? .automatic(index: blocks.firstIndex { $0.id == blockID } ?? 0)
  }
}
