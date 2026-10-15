import Foundation
import SwiftUI

/// Theme only the app-owned empty state, never authored HTML or linked data.
enum DashboardHTMLArtifactDocument {
    static func render(html: String, linkedDataJSON: String?, emptyAppearance: ColorScheme? = nil) -> String {
        let emptyStyle = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && emptyAppearance == .dark
            ? String(format: "body { background: #%06X; } .woven-empty { color: #%06X; } .woven-empty h2 { color: #%06X; }",
                     DashboardColors.darkWorkspace, DashboardColors.darkMutedForeground, DashboardColors.darkForeground)
            : ""
        let body = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? """
              <main class="woven-empty">
                <h2>HTML artifact</h2>
                <p>Ask your agent to build a visualization here.</p>
              </main>
              """
            : html
        let data = (linkedDataJSON ?? "null")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            html, body { min-height: 100%; margin: 0; }
            body { padding: 24px; box-sizing: border-box; }
            .woven-empty { min-height: calc(100vh - 48px); display: grid; place-content: center; text-align: center; color: #64706b; }
            .woven-empty h2 { margin: 0 0 6px; color: #15382d; font-size: 18px; }
            .woven-empty p { margin: 0; font-size: 13px; }
            \(emptyStyle)
          </style>
          <script>window.wovenMatterData = \(data);</script>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
