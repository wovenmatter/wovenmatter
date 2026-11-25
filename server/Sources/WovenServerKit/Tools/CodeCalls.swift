import Foundation
import WovenProtocol

/// The scripts a harness's code mode runs (`ToolKind.code`) as Woven keeps
/// them: the script without its long literals, and the tool calls it made,
/// each small. Every runtime's report of such a script passes here, through
/// `VisualReplies.withoutVisualReply`, before it is shown or saved.
///
/// A runtime reports a script as one call of kind `.code` whose `input` is
/// the script's source and whose `calls` are the tool calls it has made so
/// far, each with its arguments from `input(_:)`. It reports the whole call
/// again as the script goes on.
enum CodeCalls {
  /// The most tool calls kept for one script.
  static let callLimit = 100
  /// A string or template literal longer than this, in characters, is left
  /// out of a script's source.
  static let literalLimit = 2_000
  /// How much of a nested call's input is kept, in characters.
  static let inputLimit = 1_000
  /// How much of a nested call's error is kept, in characters.
  static let errorLimit = 2_000

  /// A nested call's arguments as its `input`: compact JSON with sorted keys.
  static func input(_ arguments: JSONValue) -> String {
    (try? Wire.encoder.encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }

  /// A script's call made ready to show and save: its long literals left out
  /// of its source, and its tool calls each kept small. A call that publishes
  /// a visual reply is marked `.visualReply` and keeps only its HTML's length,
  /// as a call outside a script does. Past `callLimit` calls, the first ones
  /// are kept and a last entry with no name says how many more there were.
  static func prepared(_ call: ToolCall) -> ToolCall {
    var call = call
    call.input = elidingLongLiterals(call.input)
    if let calls = call.calls { call.calls = capped(calls.map(nested)) }
    return call
  }

  private static func nested(_ call: ToolCall) -> ToolCall {
    var call = VisualReplies.withoutVisualReply(call)
    call.input = cut(call.input, to: inputLimit)
    call.output = call.output.map { cut($0, to: errorLimit) }
    return call
  }

  private static func capped(_ calls: [ToolCall]) -> [ToolCall] {
    guard calls.count > callLimit else { return calls }
    let kept = calls.prefix(callLimit - 1)
    return Array(kept) + [ToolCall(name: "", input: "", title: "\(calls.count - kept.count) more tool calls")]
  }

  private static func cut(_ text: String, to limit: Int) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count > limit else { return text }
    return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
  }

  /// JavaScript source with each string or template literal longer than
  /// `limit` characters replaced by its length, in the same quotes:
  /// `"(2,345 characters)"`. Literals joined only by `+` count as one, so a
  /// page built by concatenation is left out too. Comments and regular
  /// expressions are passed over. A literal that does not end is left as it
  /// is, unless it runs to the end of the source and is long.
  static func elidingLongLiterals(_ source: String, limit: Int = literalLimit) -> String {
    let text = Array(source.utf16)
    var lexer = JavaScriptLiterals(text)
    let literals = lexer.scan()
    guard !literals.isEmpty else { return source }
    // Runs of literals joined only by `+`, spaces and line breaks.
    var runs: [[JavaScriptLiterals.Literal]] = []
    for literal in literals {
      if let previous = runs.last?.last,
         text[previous.end..<literal.start].allSatisfy({ $0 == plus || isSpace($0) }),
         text[previous.end..<literal.start].contains(plus) {
        runs[runs.count - 1].append(literal)
      } else {
        runs.append([literal])
      }
    }
    var result: [UInt16] = []
    var cursor = 0
    for run in runs {
      let length = run.reduce(0) { $0 + $1.length }
      guard length > limit, let first = run.first, let last = run.last else { continue }
      result += text[cursor..<first.start]
      let quote = text[first.start]
      result.append(quote)
      result += "(\(grouped(length)) characters)".utf16
      result.append(quote)
      cursor = last.end
    }
    result += text[cursor...]
    return String(decoding: result, as: UTF16.self)
  }

  private static let plus = UInt16(UInt8(ascii: "+"))

  /// A count with thousands separated by commas: 2,345.
  private static func grouped(_ count: Int) -> String {
    let digits = String(count)
    var grouped = ""
    for (offset, digit) in digits.enumerated() {
      if offset > 0, (digits.count - offset) % 3 == 0 { grouped.append(",") }
      grouped.append(digit)
    }
    return grouped
  }

  fileprivate static func isSpace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C || unit == 0xA0
  }
}

/// A small lexer that finds a JavaScript source's string and template
/// literals, top level only: a template's `${…}` parts are read to find its
/// end, and their literals belong to it. It works on UTF-16 code units, and
/// every boundary it finds is an ASCII character.
private struct JavaScriptLiterals {
  struct Literal {
    /// The opening quote.
    var start: Int
    /// Just past the closing quote.
    var end: Int
    /// The characters between the quotes, as written.
    var length: Int { max(0, end - start - 2) }
  }

  private let text: [UInt16]
  private var index = 0
  /// What came last outside comments and spaces, to tell a regular
  /// expression from a division.
  private var previous: Previous = .start

  private enum Previous {
    case start
    /// An operator or punctuation after which an expression starts.
    case operand
    /// A name, a number, a literal or a closing bracket: a value.
    case value
    /// A keyword after which an expression starts (`return`, `typeof`…).
    case keyword
  }

  init(_ text: [UInt16]) { self.text = text }

  private func ascii(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }

  mutating func scan() -> [Literal] {
    var literals: [Literal] = []
    while index < text.count {
      if let literal = step() { literals.append(literal) }
    }
    return literals
  }

  /// Reads one token of code. Returns a literal when it read one.
  private mutating func step() -> Literal? {
    let unit = text[index]
    let next = index + 1 < text.count ? text[index + 1] : 0
    switch unit {
    case ascii("/") where next == ascii("/"):
      while index < text.count, text[index] != ascii("\n") { index += 1 }
    case ascii("/") where next == ascii("*"):
      index += 2
      while index < text.count, !(text[index] == ascii("*") && index + 1 < text.count && text[index + 1] == ascii("/")) {
        index += 1
      }
      index = min(text.count, index + 2)
    case ascii("/") where previous != .value:
      regularExpression()
    case ascii("'"), ascii("\""):
      let start = index
      previous = .value
      if quoted(unit) { return Literal(start: start, end: index) }
      // A string that does not end on its line is left as written.
      index = start + 1
    case ascii("`"):
      let start = index
      let ended = template()
      previous = .value
      if ended || index - start > CodeCalls.literalLimit { return Literal(start: start, end: index) }
    case ascii(")"), ascii("]"):
      index += 1
      previous = .value
    default:
      if CodeCalls.isSpace(unit) {
        index += 1
      } else if isWordUnit(unit) {
        let start = index
        while index < text.count, isWordUnit(text[index]) { index += 1 }
        let word = String(decoding: text[start..<index], as: UTF16.self)
        previous = Self.keywords.contains(word) ? .keyword : .value
      } else {
        index += 1
        previous = .operand
      }
    }
    return nil
  }

  /// Reads a `'` or `"` string from its opening quote. Returns false, having
  /// read nothing for good, when it does not end on its line.
  private mutating func quoted(_ quote: UInt16) -> Bool {
    var cursor = index + 1
    while cursor < text.count {
      let unit = text[cursor]
      if unit == quote { index = cursor + 1; return true }
      if unit == ascii("\\") { cursor += 2; continue }
      if unit == ascii("\n") || unit == ascii("\r") { return false }
      cursor += 1
    }
    return false
  }

  /// Reads a template literal from its backtick, with its `${…}` parts.
  /// Returns false when it runs to the end of the source.
  private mutating func template() -> Bool {
    index += 1
    while index < text.count {
      let unit = text[index]
      if unit == ascii("`") { index += 1; return true }
      if unit == ascii("\\") { index += 2; continue }
      if unit == ascii("$"), index + 1 < text.count, text[index + 1] == ascii("{") {
        index += 2
        previous = .operand
        // Code up to the brace that closes the part; literals in it belong
        // to the template.
        var depth = 1
        while index < text.count {
          if text[index] == ascii("{") { depth += 1 }
          if text[index] == ascii("}") {
            depth -= 1
            if depth == 0 { index += 1; break }
          }
          _ = step()
        }
        continue
      }
      index += 1
    }
    index = min(index, text.count)
    return false
  }

  /// Reads a regular expression from its slash, with its flags. One that
  /// does not end on its line is read as a division.
  private mutating func regularExpression() {
    var cursor = index + 1
    var inClass = false
    while cursor < text.count {
      let unit = text[cursor]
      if unit == ascii("\n") || unit == ascii("\r") { break }
      if unit == ascii("\\") { cursor += 2; continue }
      if unit == ascii("[") { inClass = true }
      else if unit == ascii("]") { inClass = false }
      else if unit == ascii("/") && !inClass {
        cursor += 1
        while cursor < text.count, isWordUnit(text[cursor]) { cursor += 1 }
        index = cursor
        previous = .value
        return
      }
      cursor += 1
    }
    index += 1
    previous = .operand
  }

  private func isWordUnit(_ unit: UInt16) -> Bool {
    (unit >= ascii("a") && unit <= ascii("z")) || (unit >= ascii("A") && unit <= ascii("Z"))
      || (unit >= ascii("0") && unit <= ascii("9")) || unit == ascii("_") || unit == ascii("$")
      || (unit >= 0x80 && !CodeCalls.isSpace(unit))
  }

  private static let keywords: Set<String> = [
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
    "yield", "await",
  ]
}
