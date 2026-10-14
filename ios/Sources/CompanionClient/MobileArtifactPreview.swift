import Foundation

/// Matches the desktop data contract; the WKWebView has no native bridge or
/// network access. Linked rows are injected into an ephemeral preview only.
public enum MobileArtifactPreview {
  public static func renderedHTML(html: String, linkedDataJSON: String? = nil) -> String {
    let data = (linkedDataJSON ?? "null")
      .replacingOccurrences(of: "&", with: "\\u0026")
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'">
    <style>:root { color-scheme: light dark; font-family: -apple-system, sans-serif; } body { margin: 0; padding: 20px; box-sizing: border-box; }</style>
    <script>window.wovenMatterData = \(data);</script></head><body>\(html)</body></html>
    """
  }
}
