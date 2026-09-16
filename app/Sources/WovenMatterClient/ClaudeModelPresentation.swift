import Foundation

/// Claude context variants share a menu entry only when supplied metadata
/// identifies the same version and exact base ID. Selection IDs remain untouched.
enum ClaudeModelPresentation {
    static func metadata(id: String, supplied: SessionOptionMetadata) -> SessionOptionMetadata {
        if id == "default" {
            return SessionOptionMetadata(name: "default", description: supplied.description)
        }
        let selectionBase = id.hasSuffix("[1m]") ? String(id.dropLast("[1m]".count)) : id
        let base = selectionBase.hasPrefix("claude-")
            ? String(selectionBase.dropFirst("claude-".count)) : selectionBase
        let family = String(base.prefix { $0.isLetter })
        guard !family.isEmpty else { return supplied }
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: family)
            + "\\s+(\\d+(?:\\.\\d+)*)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return supplied }
        for text in [supplied.name, supplied.description].compactMap({ $0 }) {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let version = String(text[range])
            return SessionOptionMetadata(name: family.capitalized + " " + version,
                description: supplied.description,
                modelGroup: "claude:" + selectionBase + ":" + version)
        }
        return supplied
    }
}
