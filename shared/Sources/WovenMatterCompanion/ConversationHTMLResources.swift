import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Preparation belongs to the invoking CLI/device, never the observing Mac.
/// Matches T3's authored-page, image, and prepared-page budgets.
public enum ConversationHTMLResources {
  public static let maximumAuthoredCharacters = 512_000
  public static let maximumImageBytes = 10 * 1_024 * 1_024
  public static let maximumPageBytes = 25 * 1_024 * 1_024

  public struct Prepared: Sendable {
    public let html: String
    public let missingImages: [String]
  }

  public static func prepareJSON(_ source: String, resolve: ((String) throws -> URL)? = nil) throws -> String {
    guard var input = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
          let html = input["html"] as? String,
          let action = input["action"] as? String, ["render", "preview"].contains(action),
          html.utf16.count <= maximumAuthoredCharacters else {
      throw WorkspaceToolError.invalid("HTML tools require a render/preview action and at most 512,000 authored characters.")
    }
    let prepared = try prepare(html, resolve: resolve)
    if action == "render", !prepared.missingImages.isEmpty {
      throw WorkspaceToolError.invalid("Local images could not be read as images: " + prepared.missingImages.joined(separator: ", "))
    }
    input["html"] = prepared.html
    if action == "preview", !prepared.missingImages.isEmpty { input["missingImages"] = prepared.missingImages }
    return String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }

  public static func prepare(_ html: String, resolve: ((String) throws -> URL)? = nil) throws -> Prepared {
    guard html.utf16.count <= maximumAuthoredCharacters else { throw WorkspaceToolError.invalid("HTML exceeds 512,000 authored characters.") }
    // Quoted HTML/JS/CSS paths, including backticks, and bare CSS url(/path).
    // Exclude protocol-relative URLs. Bound paths to keep scans linear.
    let expression = try NSRegularExpression(pattern: #"(["'`])((?:/(?!/)|[a-z]:[\\/])(?:(?!\1)[^\r\n]){0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\1|url\(\s*((?:/(?!/)|[a-z]:[\\/])[^\s"'`()]{0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\s*\)"#, options: .caseInsensitive)
    let source = html as NSString
    let references = expression.matches(in: html, range: NSRange(location: 0, length: source.length)).map { match -> NSRange in
      match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
    }
    var images: [String: String] = [:], missing: [String] = [], missingSet: Set<String> = [], pageBytes = html.utf8.count
    for range in references {
      let path = source.substring(with: range)
      if images[path] == nil && !missingSet.contains(path) {
        let url = try resolve?(path) ?? URL(fileURLWithPath: path)
        let bytes: Data?
        do { bytes = try readImage(url) }
        catch ImageReadError.tooLarge { throw WorkspaceToolError.invalid("Local image exceeds 10 MiB: " + path) }
        catch { bytes = nil }
        if let bytes, let mime = imageMIME(bytes) {
          images[path] = "data:\(mime);base64," + bytes.base64EncodedString()
        } else { missing.append(path); missingSet.insert(path) }
      }
      if let uri = images[path] { pageBytes += uri.utf8.count - path.utf8.count }
      guard pageBytes <= maximumPageBytes else { throw WorkspaceToolError.invalid("The page exceeds 25 MiB after embedding its images.") }
    }
    var output = "", cursor = 0
    for range in references {
      let path = source.substring(with: range)
      guard let uri = images[path] else { continue }
      output += source.substring(with: NSRange(location: cursor, length: range.location - cursor)) + uri
      cursor = NSMaxRange(range)
    }
    output += source.substring(from: cursor)
    return Prepared(html: output, missingImages: missing)
  }

  private enum ImageReadError: Error { case tooLarge }
  private static func readImage(_ url: URL) throws -> Data {
    // A FIFO/device must never block preparation. Check the opened descriptor,
    // not a preceding path stat that can race with a symlink replacement.
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw WorkspaceToolError.invalid("Image could not be opened.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw WorkspaceToolError.invalid("Images must be regular files.") }
    guard info.st_size <= maximumImageBytes else { throw ImageReadError.tooLarge }
    let bytes = try handle.read(upToCount: maximumImageBytes + 1) ?? Data()
    guard bytes.count <= maximumImageBytes else { throw ImageReadError.tooLarge }
    return bytes
  }

  public static func imageMIME(_ bytes: Data) -> String? {
    let head = [UInt8](bytes.prefix(12))
    if head.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
    if head.starts(with: [255,216,255]) { return "image/jpeg" }
    if head.starts(with: Array("GIF8".utf8)) { return "image/gif" }
    if head.starts(with: [0,0,1,0]) { return "image/x-icon" }
    if head.starts(with: Array("BM".utf8)), head.count >= 10, head[6..<10].allSatisfy({ $0 == 0 }) { return "image/bmp" }
    if head.count == 12, head.starts(with: Array("RIFF".utf8)), String(bytes: head[8...], encoding: .ascii) == "WEBP" { return "image/webp" }
    if head.count == 12, ["ftypavif", "ftypavis", "ftypmif1"].contains(String(bytes: head[4...], encoding: .ascii) ?? "") { return "image/avif" }
    let prefix = String(decoding: bytes.prefix(4096), as: UTF8.self)
    if svgRoot(prefix) { return "image/svg+xml" }
    return nil
  }

  private static func svgRoot(_ source: String) -> Bool {
    var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    while !text.isEmpty {
      if text.hasPrefix("<?"), let end = text.range(of: "?>") { text = String(text[end.upperBound...]) }
      else if text.hasPrefix("<!--"), let end = text.range(of: "-->") { text = String(text[end.upperBound...]) }
      else if text.lowercased().hasPrefix("<!doctype") {
        var quoted: Character?, subset = 0, end: String.Index?
        for index in text.indices.dropFirst(9) {
          let char = text[index]
          if let quote = quoted { if char == quote { quoted = nil } }
          else if char == "\"" || char == "'" { quoted = char }
          else if char == "[" { subset += 1 }
          else if char == "]" { subset -= 1 }
          else if char == ">", subset == 0 { end = text.index(after: index); break }
        }
        guard let end else { return false }; text = String(text[end...])
      } else { return text.range(of: #"^<svg[\s/>]"#, options: .regularExpression) != nil }
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return false
  }
}
