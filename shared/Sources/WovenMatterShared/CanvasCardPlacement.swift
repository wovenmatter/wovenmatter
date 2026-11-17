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
  /// An image stored in the Page itself. It never changes after it is added.
  public var image: PageImage?

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
      && (image?.isValid ?? true) && (image == nil || assetID == nil)
  }
}

/// A PNG, JPEG or GIF kept inside a Page, so it travels with the Page and needs
/// no separate file. Pages have a size limit, so images are stored small.
public struct PageImage: Codable, Equatable, Sendable {
  public static let maximumBytes = 360_000
  public static let mediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif"]
  public var mediaType: String
  /// Base64 of the image bytes.
  public var data: String
  public var alt: String?
  public var width: Int?
  public var height: Int?

  public init(mediaType: String, data: String, alt: String? = nil, width: Int? = nil, height: Int? = nil) {
    self.mediaType = mediaType; self.data = data; self.alt = alt; self.width = width; self.height = height
  }

  public init(mediaType: String, bytes: Data, alt: String? = nil, width: Int? = nil, height: Int? = nil) {
    self.init(mediaType: mediaType, data: bytes.base64EncodedString(), alt: alt, width: width, height: height)
  }

  public var bytes: Data? { Data(base64Encoded: data) }

  var isValid: Bool {
    Self.mediaTypes.contains(mediaType) && data.utf8.count <= (Self.maximumBytes + 2) / 3 * 4
      && (alt?.utf8.count ?? 0) <= 1_024
      && (width ?? 1) > 0 && (height ?? 1) > 0 && (width ?? 0) <= 20_000 && (height ?? 0) <= 20_000
  }
}

public extension NoteDocument {
  /// The stored placement, or an empty one. A Page keeps placements only for an
  /// original's label and embed height, and for layout kept from an older Board.
  func canvasPlacement(for blockID: String) -> CanvasCardPlacement {
    canvas?[blockID] ?? CanvasCardPlacement(x: 0, y: 0)
  }
}
