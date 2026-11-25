import Foundation
import WovenProtocol

/// Model lists newest release first, by the rule the bots runtime and Pi Durable
/// keep for theirs (`bots/src/model-catalog.ts`, `default-agent/src/models.mjs`).
/// The harnesses report no release dates, so the version numbers in a model's id
/// decide, highest first (gpt-6.2 before gpt-6.1 before gpt-6 before gpt-5.6),
/// then the name. An id with no version takes its name's (Claude Code's `opus`
/// is "Opus 5.5"). Dates (2024-08-06, 12-2024, 20251001) and sizes (70b, 8x22b,
/// 32k, 1m) are not versions, and a model with no version goes last. A
/// harness's own `default` choice (Claude Code's "Default (recommended)")
/// stays first. Ids that name a lab (`anthropic/claude-opus-5.5`) keep each
/// lab's models together, labs by name.
enum ModelOrder {
  private static let dates = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}|(?<!\d)\d{2}-\d{4}(?!\d)"#)
  private static let numbers = try! NSRegularExpression(pattern: #"(?<!\d)\d{1,3}(?![\dbBkKmM]|x\d)"#)

  static func version(_ text: String) -> [Int] {
    let undated = dates.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    return numbers.matches(in: undated, range: NSRange(undated.startIndex..., in: undated)).compactMap {
      Range($0.range, in: undated).flatMap { Int(undated[$0]) }
    }
  }

  static func newestFirst<T>(_ items: [T], id: (T) -> String, name: (T) -> String) -> [T] {
    let keyed = items.map { item -> (item: T, id: String, name: String, first: Bool, lab: String, version: [Int]) in
      let id = id(item), name = name(item)
      let slash = id.firstIndex(of: "/")
      let bare = slash.map { String(id[id.index(after: $0)...]) } ?? id
      let own = version(bare)
      return (item, id, name, bare == "default", slash.map { String(id[..<$0]) } ?? "", own.isEmpty ? version(name) : own)
    }
    return keyed.sorted { a, b in
      if a.first != b.first { return a.first }
      if a.lab != b.lab { return a.lab < b.lab }
      for index in 0..<max(a.version.count, b.version.count) {
        // The longer version is the later one: 6.1 follows 6.
        guard index < a.version.count else { return false }
        guard index < b.version.count else { return true }
        if a.version[index] != b.version[index] { return a.version[index] > b.version[index] }
      }
      let names = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
      return names == .orderedSame ? a.id < b.id : names == .orderedAscending
    }.map(\.item)
  }

  static func newestFirst(_ options: [SessionOption]) -> [SessionOption] {
    newestFirst(options, id: \.id, name: \.name)
  }
}
