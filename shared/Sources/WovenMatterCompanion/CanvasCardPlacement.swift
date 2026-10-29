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

  public init(x: Double, y: Double, width: Double = 360, height: Double = 300, assetID: String? = nil) {
    self.x = x; self.y = y; self.width = width; self.height = height; self.assetID = assetID
  }

  public static func automatic(index: Int) -> Self {
    Self(x: 24 + Double(index % 5) * 392, y: 24 + Double(index / 5) * 332)
  }

  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && (0...20_000).contains(x) && (0...20_000).contains(y)
      && (280...960).contains(width) && (200...960).contains(height)
      && (assetID.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? true)
  }
}

public extension NoteDocument {
  static let maximumCanvasCards = 200

  func canvasPlacement(for blockID: String) -> CanvasCardPlacement {
    canvas?[blockID] ?? .automatic(index: blocks.firstIndex { $0.id == blockID } ?? 0)
  }
}
