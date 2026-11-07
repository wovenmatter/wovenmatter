import Foundation
import WovenMatterCompanion

/// Matches the desktop data contract; the WKWebView has no native bridge or
/// network access. Linked rows are injected into an ephemeral preview only.
public enum MobileArtifactPreview {
  public static func renderedHTML(html: String, linkedDataJSON: String? = nil, state: ArtifactStateSnapshot? = nil) -> String {
    let data = scriptJSON(linkedDataJSON ?? "null")
    let bootstrap: String
    if let state {
      let configuration = Configuration(token: "mobile-read-only", state: state, editable: false)
      let json = (try? String(decoding: JSONEncoder().encode(configuration), as: UTF8.self)) ?? "{}"
      bootstrap = "<script>window.__wovenArtifactConfiguration = \(scriptJSON(json));\n\(ArtifactStateJavaScript.bootstrap)</script>"
    } else { bootstrap = "" }
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'">
    <style>:root { color-scheme: light dark; font-family: -apple-system, sans-serif; } body { margin: 0; padding: 20px; box-sizing: border-box; }</style>
    <script>window.wovenMatterData = \(data);</script>\(bootstrap)</head><body>\(html)</body></html>
    """
  }

  private struct Configuration: Encodable {
    let token: String
    let state: ArtifactStateSnapshot
    let editable: Bool
  }

  private static func scriptJSON(_ json: String) -> String {
    json
      .replacingOccurrences(of: "&", with: "\\u0026")
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }
}
