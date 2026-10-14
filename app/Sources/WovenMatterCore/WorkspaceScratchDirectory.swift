import Foundation

/// A readable name whose identity belongs to the chat, independently of later titles.
public enum WorkspaceScratchDirectory {
    public static func name(sessionID: String, firstMessage: String, date: Date = Date(), fullID: Bool = false) -> String {
        let words = firstMessage.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }.prefix(5).joined(separator: "-")
        let slug = String(words.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = sessionID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return [String(ISO8601DateFormatter().string(from: date).prefix(10)), slug,
                fullID ? id : String(id.suffix(8))].filter { !$0.isEmpty }.joined(separator: "-")
    }
}
