import Foundation
import WovenProtocol

/// A page an agent wrote, made ready to show: its local images embedded.
struct PreparedPage: Sendable, Hashable {
  var html: String
  /// Absolute local image paths the page refers to that are missing,
  /// unreadable, too large or not images, each once, in the order met.
  var missingImages: [String]
}

/// The pages agents publish in a chat (`render_html`) and check first
/// (`preview_html`), on the machine where the session runs.
enum HTMLPages {
  /// The most an authored page may be, in UTF-16 code units.
  static let authoredLimit = 512_000
  /// The largest local image that is embedded.
  static let imageLimit = 10 << 20
  /// The largest page once its images are embedded, in UTF-8 bytes.
  static let pageLimit = 25 << 20

  /// Absolute local image paths: in quotes (HTML attributes, CSS, JavaScript
  /// strings and backticks), or bare in CSS `url(...)`. A path that starts
  /// with `//` is a protocol-relative URL and stays as it is.
  private static let references = try! NSRegularExpression(pattern: #"""
    (["'`])(/(?!/)(?:(?!\1)[^\r\n]){0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\1|url\(\s*(/(?!/)[^\s"'`()]{0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\s*\)
    """#, options: [.caseInsensitive])

  /// Embeds each local image the page refers to as a data URI. A path read
  /// once is embedded everywhere it appears. Fails when the page is empty or
  /// too long, or would be over `pageLimit`.
  static func prepare(_ html: String) throws -> PreparedPage {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolFailure("Give `html`.") }
    guard html.utf16.count <= authoredLimit else {
      throw ToolFailure("The page is longer than 512,000 characters.")
    }
    let source = html as NSString
    let matches = references.matches(in: html, range: NSRange(location: 0, length: source.length))
    var images: [String: String] = [:]
    var missing: [String] = []
    var size = html.utf8.count
    var pieces: [String] = []
    var cursor = 0
    for match in matches {
      let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
      let path = source.substring(with: range)
      if images[path] == nil, !missing.contains(path) {
        if let uri = dataURI(path) { images[path] = uri } else { missing.append(path) }
      }
      guard let uri = images[path] else { continue }
      size += uri.utf8.count - path.utf8.count
      guard size <= pageLimit else { throw ToolFailure("The page would be over 25 MiB with its images embedded.") }
      pieces.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      pieces.append(uri)
      cursor = NSMaxRange(range)
    }
    pieces.append(source.substring(from: cursor))
    return PreparedPage(html: pieces.joined(), missingImages: missing)
  }

  /// The one rule that keeps a page from being saved twice. The page is
  /// saved once, as its own item, when `render_html` runs; every runtime also
  /// reports the call, and that report is kept without the page: each `html`
  /// argument becomes its length, and the call is marked `.page` so the chat
  /// shows the page, not the call. Every runtime's tool calls pass here
  /// (`SessionHost`, and the bots' mirror) before they are shown or saved.
  static func withoutPage(_ call: ToolCall) -> ToolCall {
    guard publishes(call) else { return call }
    var call = call
    call.kind = .page
    if let input = try? JSONDecoder().decode(JSONValue.self, from: Data(call.input.utf8)), case .object = input {
      call.input = (try? String(decoding: Wire.encoder.encode(withoutHTML(input)), as: UTF8.self)) ?? ""
    } else if !call.input.isEmpty {
      // Cut short on the way, so no longer JSON.
      call.input = #"{"html":"(the page, shown in the chat)"}"#
    }
    return call
  }

  /// Whether a runtime's tool call is Woven's `render_html`, by the name or
  /// title the runtime gives it (`render_html`, `woven_render_html`,
  /// `mcp__woven__render_html`, `woven/render_html`).
  static func publishes(_ call: ToolCall) -> Bool {
    [call.name, call.title ?? ""].contains { name in
      name.lowercased().firstMatch(of: #/(^|[^a-z0-9])render_html($|[^a-z0-9_])/#) != nil
    }
  }

  private static func withoutHTML(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      .object(fields.mapValues(withoutHTML).merging(
        fields["html"]?.string.map { ["html": .string("(\($0.utf16.count) characters, shown in the chat)")] } ?? [:],
        uniquingKeysWith: { _, page in page }))
    case .array(let values): .array(values.map(withoutHTML))
    default: value
    }
  }

  /// A regular file of at most `imageLimit` whose bytes are an image, as a
  /// data URI; nil otherwise.
  private static func dataURI(_ path: String) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = (attributes[.size] as? NSNumber)?.intValue, size <= imageLimit,
          let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: imageLimit + 1), data.count <= imageLimit,
          let type = imageType(data) else { return nil }
    return "data:\(type);base64," + data.base64EncodedString()
  }

  /// The image type the bytes' signature says, or nil when they are not an image.
  static func imageType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
      bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
    }
    if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if starts(Array("GIF8".utf8)) { return "image/gif" }
    if starts([0, 0, 1, 0]) { return "image/x-icon" }
    if starts(Array("BM".utf8)), starts([0, 0, 0, 0], at: 6) { return "image/bmp" }
    if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
    if starts(Array("ftyp".utf8), at: 4), ["avif", "avis", "mif1"].contains(where: { starts(Array($0.utf8), at: 8) }) {
      return "image/avif"
    }
    return isSVG(data) ? "image/svg+xml" : nil
  }

  /// Text whose first element, after any XML declaration, comments and
  /// doctype, is `<svg`.
  private static func isSVG(_ data: Data) -> Bool {
    var text = Substring(String(decoding: data.prefix(4096), as: UTF8.self))
    func skipSpace() { text = text.drop(while: \.isWhitespace) }
    skipSpace()
    while !text.isEmpty {
      if text.hasPrefix("<?") || text.hasPrefix("<!--") {
        guard let end = text.range(of: text.hasPrefix("<?") ? "?>" : "-->") else { return false }
        text = text[end.upperBound...]
      } else if text.lowercased().hasPrefix("<!doctype") {
        var quote: Character?
        var subset = 0
        var end: Substring.Index?
        for index in text.indices.dropFirst(9) {
          let character = text[index]
          if let open = quote {
            if character == open { quote = nil }
          } else if character == "\"" || character == "'" {
            quote = character
          } else if character == "[" {
            subset += 1
          } else if character == "]" {
            subset -= 1
          } else if character == ">" && subset == 0 {
            end = text.index(after: index)
            break
          }
        }
        guard let end else { return false }
        text = text[end...]
      } else {
        guard text.hasPrefix("<svg"), let next = text.dropFirst(4).first else { return false }
        return next.isWhitespace || next == "/" || next == ">"
      }
      skipSpace()
    }
    return false
  }
}
