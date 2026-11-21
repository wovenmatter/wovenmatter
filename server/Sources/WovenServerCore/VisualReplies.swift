import Foundation
import WovenProtocol

/// A failure the agent reads as the tool's result.
package struct ToolFailure: Error, CustomStringConvertible {
  package let description: String
  package init(_ description: String) { self.description = description }
}

/// A visual reply's HTML as an agent wrote it, made ready to show: its local
/// images embedded.
package struct PreparedVisualReply: Sendable, Hashable {
  package var html: String
  /// Absolute local image paths the HTML refers to that were not embedded
  /// (missing, unreadable, too large, not images, or not read at all), each
  /// once, in the order met.
  package var missingImages: [String]
}

/// The visual replies agents publish in a chat (`render_html`) and check
/// first (`preview_html`), on the machine where the session runs. A visual
/// reply is not a Page artifact.
package enum VisualReplies {
  /// The most authored HTML may be, in UTF-16 code units.
  package static let authoredLimit = 512_000
  /// The largest local image that is embedded.
  package static let imageLimit = 10 << 20
  /// The largest HTML once its images are embedded, in UTF-8 bytes.
  package static let embeddedLimit = 25 << 20

  /// Absolute local image paths: in quotes (HTML attributes, CSS, JavaScript
  /// strings and backticks), or bare in CSS `url(...)`. A path that starts
  /// with `//` is a protocol-relative URL and stays as it is.
  private static let references = try! NSRegularExpression(pattern: #"""
    (["'`])(/(?!/)(?:(?!\1)[^\r\n]){0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\1|url\(\s*(/(?!/)[^\s"'`()]{0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\s*\)
    """#, options: [.caseInsensitive])

  /// Lengths relative to the viewport's height. The frame takes the HTML's
  /// height, so such HTML would grow with its frame without end.
  private static let viewportHeights = try! NSRegularExpression(
    pattern: #"(?<![\w.-])\d*\.?\d+\s*[sld]?(?:vh|vmin|vmax)\b"#, options: [.caseInsensitive])

  /// Embeds each local image the HTML refers to as a data URI. A path read
  /// once is embedded everywhere it appears. Fails when the HTML is empty or
  /// too long, uses viewport-height lengths, or would be over `embeddedLimit`.
  /// `readingDisk` false (a bot, whose files are in its own machine, not this
  /// one) reads nothing: the HTML stays as authored and every local path is
  /// in `missingImages`.
  package static func prepare(_ html: String, readingDisk: Bool = true) throws -> PreparedVisualReply {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolFailure("Give `html`.") }
    guard html.utf16.count <= authoredLimit else {
      throw ToolFailure("The visual reply is longer than 512,000 characters.")
    }
    if let found = viewportHeights.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
      throw ToolFailure("The visual reply sizes something by the viewport (\((html as NSString).substring(with: found.range))). "
                        + "The frame fits its content's height, so give heights in px or let the content set them.")
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
        if readingDisk, let uri = dataURI(path) { images[path] = uri } else { missing.append(path) }
      }
      guard let uri = images[path] else { continue }
      size += uri.utf8.count - path.utf8.count
      guard size <= embeddedLimit else { throw ToolFailure("The visual reply would be over 25 MiB with its images embedded.") }
      pieces.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      pieces.append(uri)
      cursor = NSMaxRange(range)
    }
    pieces.append(source.substring(from: cursor))
    return PreparedVisualReply(html: pieces.joined(), missingImages: missing)
  }

  /// The one rule that keeps a visual reply from being saved twice. It is
  /// saved once, as its own item, when `render_html` runs; every runtime also
  /// reports the call, and that report is kept without its HTML: each `html`
  /// argument becomes its length, and the call is marked `.visualReply` so
  /// the chat shows the visual reply, not the call. Every runtime's tool calls pass here
  /// (`SessionHost`, and the bots' mirror) before they are shown or saved.
  package static func withoutVisualReply(_ call: ToolCall) -> ToolCall {
    guard publishes(call) else { return call }
    var call = call
    call.kind = .visualReply
    if let input = try? JSONDecoder().decode(JSONValue.self, from: Data(call.input.utf8)), case .object = input {
      call.input = (try? String(decoding: Wire.encoder.encode(withoutHTML(input)), as: UTF8.self)) ?? ""
    } else if !call.input.isEmpty {
      // Cut short on the way, so no longer JSON.
      call.input = #"{"html":"(the visual reply, shown in the chat)"}"#
    }
    return call
  }

  /// Whether a runtime's tool call is Woven's `render_html`, by the name or
  /// title the runtime gives it: the tool's own name, alone or after the
  /// `woven` server and whatever separator the runtime puts between them
  /// (Claude Code and Pi Durable `mcp__woven__render_html`, Codex
  /// `mcp.woven.render_html`, OpenCode and the bots `woven_render_html`,
  /// `woven/render_html`, `woven: render_html`). Another server's
  /// `render_html` is not Woven's.
  package static func publishes(_ call: ToolCall) -> Bool {
    [call.name, call.title ?? ""].contains { name in
      name.trimmingCharacters(in: .whitespaces).lowercased()
        .wholeMatch(of: #/(?:(?:.*[^a-z0-9])?woven(?:__|[_.\/:]\s*|\s+))?render_html/#) != nil
    }
  }

  /// The HTML's own `<title>`, when it has a non-empty one, in one line.
  package static func title(of html: String) -> String? {
    guard let match = html.firstMatch(of: #/(?is)<title\b[^>]*>(.*?)</title\s*>/#) else { return nil }
    let text = String(match.1).split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
    return text.isEmpty ? nil : String(text.prefix(200))
  }

  private static func withoutHTML(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      .object(fields.mapValues(withoutHTML).merging(
        fields["html"]?.string.map { ["html": .string("(\($0.utf16.count) characters, shown in the chat)")] } ?? [:],
        uniquingKeysWith: { _, shown in shown }))
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
  package static func imageType(_ data: Data) -> String? {
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
