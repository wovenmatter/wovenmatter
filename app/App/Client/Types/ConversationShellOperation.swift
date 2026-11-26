import Foundation

/// What a shell command did, when it is one of the common read-only forms a
/// file tool also does: a search, a listing or reading one file. Anything
/// else is not recognised, so a row never claims an operation its command did
/// not do: several commands joined together, a program given by its path, an
/// option this does not know to be harmless, an operand that is not a plain
/// path, and anything the shell would expand.
public enum ConversationShellOperation: Equatable, Sendable {
  case search(pattern: String, path: String?)
  case list(path: String?)
  case read(path: String)

  /// The operation of `command`, run in `folder` when known. A leading
  /// `cd <dir> &&` sets the folder; a pipeline counts as its first command
  /// when everything after it only filters that command's output.
  public static func recognize(_ command: String, folder: String? = nil) -> ConversationShellOperation? {
    var command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    var folder = folder
    // `cd <pattern> &&` (Pi writes `cd /tmp/*sample &&`): what follows ran
    // only if the shell found one folder, but which is not certain, so its
    // paths keep their own words.
    if let range = command.range(of: #"^cd +[^\s;&|<>$`'"(){}]*[*?\[][^\s;&|<>$`'"(){}]* *&& *"#, options: .regularExpression) {
      command.removeSubrange(range)
      folder = nil
    }
    guard var words = Self.words(command) else { return nil }
    // `cd <dir> &&` in front sets the folder for what follows. After `;` the
    // rest would run where it was if `cd` failed.
    if words.count > 3, words[0] == .word("cd"), case .word(let dir) = words[1], words[2] == .control("&&") {
      guard let joined = path(dir, in: folder) else { return nil }
      folder = joined
      words.removeFirst(3)
    }
    // A pipeline of one command and pure filters; nothing else joined to it.
    var stages: [[String]] = [[]]
    for word in words {
      switch word {
      case .word(let text): stages[stages.count - 1].append(text)
      case .control("|"): stages.append([])
      case .control: return nil
      }
    }
    guard let first = stages.first, !first.isEmpty, stages.allSatisfy({ !$0.isEmpty }),
          stages.dropFirst().allSatisfy(isFilter) else { return nil }
    return operation(first, folder: folder)
  }

  // MARK: Commands

  private static func operation(_ words: [String], folder: String?) -> ConversationShellOperation? {
    guard let program = words.first, isProgramName(program) else { return nil }
    let arguments = Array(words.dropFirst())
    /// One plain path, or none (the folder itself); more is not one operation.
    func place(_ operands: [String]) -> String?? {
      guard operands.count <= 1 else { return nil }
      guard let operand = operands.first else { return .some(folder) }
      return path(operand, in: folder).map { .some($0) }
    }
    switch program {
    case "grep", "egrep", "rg":
      guard let parsed = parse(arguments, program == "rg" ? .ripgrep : .grep) else { return nil }
      var operands = parsed.operands
      // One pattern: from -e, else the first operand.
      guard parsed.patterns.count <= 1,
            let pattern = parsed.patterns.first ?? (operands.isEmpty ? nil : operands.removeFirst()),
            !pattern.isEmpty else { return nil }
      // grep with no path reads its input: not a search of files.
      if program != "rg", operands.isEmpty { return nil }
      guard let path = place(operands) else { return nil }
      return .search(pattern: pattern, path: path)
    case "ls":
      guard let parsed = parse(arguments, .ls), parsed.patterns.isEmpty,
            let path = place(parsed.operands) else { return nil }
      return .list(path: path)
    case "tree":
      guard let parsed = parse(arguments, .tree), parsed.patterns.isEmpty,
            let path = place(parsed.operands) else { return nil }
      return .list(path: path)
    case "find":
      return findListing(arguments, folder: folder)
    case "cat", "nl", "wc", "head", "tail":
      let options: Options = switch program {
      case "cat": .cat
      case "wc": .wc
      case "head", "tail": .headTail
      default: .none
      }
      guard let parsed = parse(arguments, options), parsed.patterns.isEmpty, parsed.operands.count == 1,
            let path = path(parsed.operands[0], in: folder) else { return nil }
      return .read(path: path)
    case "sed":
      // Only `sed -n '<lines>p' <file>`: printing lines, never editing.
      guard arguments.count == 3, arguments[0] == "-n",
            arguments[1].range(of: #"^(\d+|\$)(,(\d+|\$))?p$"#, options: .regularExpression) != nil,
            let path = path(arguments[2], in: folder) else { return nil }
      return .read(path: path)
    default:
      return nil
    }
  }

  /// `find <path> <tests>`, listing one folder: only tests that select or
  /// print, never one that acts, writes or runs anything.
  private static func findListing(_ arguments: [String], folder: String?) -> ConversationShellOperation? {
    guard let first = arguments.first, !first.hasPrefix("-"), first != "(", first != "!",
          let start = path(first, in: folder) else { return nil }
    let bare: Set<String> = ["-print", "-print0", "-prune", "-empty", "-depth", "-ls", "-not", "!", "(", ")",
                             "-o", "-or", "-a", "-and", "-true", "-false", "-xdev"]
    let valued: Set<String> = ["-name", "-iname", "-path", "-ipath", "-wholename", "-type", "-maxdepth",
                               "-mindepth", "-size", "-mtime", "-mmin", "-atime", "-ctime", "-newer",
                               "-regex", "-iregex", "-user", "-group", "-perm", "-links"]
    var index = 1
    while index < arguments.count {
      let test = arguments[index]
      index += 1
      if bare.contains(test) { continue }
      guard valued.contains(test), index < arguments.count else { return nil }
      index += 1
    }
    return .list(path: start)
  }

  /// The options a recognised command may carry, all of which only change
  /// what it shows. Anything else declines the command.
  private struct Options {
    /// Short flags without a value.
    var flags: Set<Character> = []
    /// Short flags taking a value, attached or the next word.
    var values: Set<Character> = []
    /// Value flags whose value must be a count.
    var counts: Set<Character> = []
    var longFlags: Set<String> = []
    var longValues: Set<String> = []
    var longCounts: Set<String> = []
    /// Long flags whose optional value can only be attached (`--color=never`).
    var longAttached: Set<String> = []
    /// A count as a flag of its own (`head -40`).
    var numberFlag = false

    static let none = Options()
    static let grep = Options(
      flags: Set("rRniwlcHhsFEoIx"), values: Set("eABCm"), counts: Set("ABCm"),
      longFlags: ["recursive", "dereference-recursive", "line-number", "ignore-case", "word-regexp", "line-regexp",
                  "files-with-matches", "count", "with-filename", "no-filename", "no-messages", "fixed-strings",
                  "extended-regexp", "only-matching"],
      longValues: ["include", "exclude", "exclude-dir", "regexp", "max-count", "context", "after-context",
                   "before-context"],
      longCounts: ["max-count", "context", "after-context", "before-context"],
      longAttached: ["color", "colour"])
    static let ripgrep = Options(
      flags: Set("iSsnNwxFlcoHuLU"), values: Set("egtTABCmMj"), counts: Set("ABCmMj"),
      longFlags: ["ignore-case", "smart-case", "case-sensitive", "line-number", "no-line-number", "word-regexp",
                  "line-regexp", "fixed-strings", "files-with-matches", "count", "only-matching", "with-filename",
                  "no-filename", "hidden", "no-ignore", "follow", "no-heading", "heading", "vimgrep", "column",
                  "multiline", "unrestricted", "trim"],
      longValues: ["glob", "iglob", "type", "type-not", "max-count", "context", "after-context", "before-context",
                   "regexp", "max-depth", "max-columns", "threads", "max-filesize", "color", "colour", "colors", "sort",
                   "sortr"],
      longCounts: ["max-count", "context", "after-context", "before-context", "max-depth", "max-columns", "threads"])
    static let ls = Options(
      flags: Set("aAlh1RtrSFpdGi"),
      longFlags: ["all", "almost-all", "human-readable", "recursive", "classify", "directory"],
      longAttached: ["color", "colour"])
    static let tree = Options(
      flags: Set("adfFshDCix"), values: Set("LIP"), counts: ["L"],
      longFlags: ["noreport", "dirsfirst", "gitignore"])
    static let cat = Options(flags: Set("nbsv"))
    static let wc = Options(flags: Set("lwcm"))
    static let headTail = Options(
      flags: ["q"], values: Set("nc"), counts: Set("nc"), longValues: ["lines", "bytes"],
      longCounts: ["lines", "bytes"], numberFlag: true)
    static let sort = Options(
      flags: Set("rnufhVbd"), values: Set("kt"), longFlags: ["reverse", "numeric-sort", "unique"])
    static let uniq = Options(flags: Set("cdui"))
    static let cut = Options(flags: ["s"], values: Set("dfcb"))
    static let grepFilter = Options(
      flags: Set("niwcvxFEohHsI"), values: Set("eABCm"), counts: Set("ABCm"),
      longFlags: ["ignore-case", "invert-match", "count", "word-regexp", "fixed-strings", "extended-regexp",
                  "only-matching", "line-number"],
      longAttached: ["color", "colour"])
  }

  /// The patterns given with `-e` or `--regexp`, and the operands; nil when
  /// an argument is not one of `options`.
  private static func parse(_ arguments: [String], _ options: Options) -> (patterns: [String], operands: [String])? {
    func isCount(_ value: String) -> Bool {
      let digits = value.first == "+" || value.first == "-" ? value.dropFirst() : value[...]
      return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
    var patterns: [String] = []
    var operands: [String] = []
    var index = 0
    var flagsEnded = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if flagsEnded || !argument.hasPrefix("-") || argument == "-" {
        operands.append(argument)
      } else if argument == "--" {
        flagsEnded = true
      } else if argument.hasPrefix("--") {
        let body = argument.dropFirst(2)
        let name = String(body.prefix { $0 != "=" })
        let attached = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) }
        if options.longAttached.contains(name) {
          // `--color never` passes `never` as an operand, which a reader
          // would not expect: only the attached form is certain.
          guard attached != nil else { return nil }
          continue
        }
        if options.longFlags.contains(name) {
          guard attached == nil else { return nil }
          continue
        }
        guard options.longValues.contains(name) else { return nil }
        let value: String
        if let attached {
          value = attached
        } else {
          guard index < arguments.count else { return nil }
          value = arguments[index]
          index += 1
        }
        if options.longCounts.contains(name), !isCount(value) { return nil }
        if name == "regexp" { patterns.append(value) }
      } else {
        // A cluster such as -rniw, or -A3, or -e PATTERN.
        let letters = Array(argument.dropFirst())
        if letters.allSatisfy({ $0.isASCII && $0.isNumber }) {   // head -40
          guard options.numberFlag else { return nil }
          continue
        }
        for (offset, letter) in letters.enumerated() {
          if options.flags.contains(letter) { continue }
          guard options.values.contains(letter) else { return nil }
          let rest = String(letters[(offset + 1)...])
          let value: String
          if rest.isEmpty {
            guard index < arguments.count else { return nil }
            value = arguments[index]
            index += 1
          } else {
            value = rest
          }
          if options.counts.contains(letter), !isCount(value) { return nil }
          if letter == "e" { patterns.append(value) }
          break
        }
      }
    }
    return (patterns, operands)
  }

  /// A command that only filters what is piped into it.
  private static func isFilter(_ words: [String]) -> Bool {
    guard let program = words.first, isProgramName(program) else { return false }
    let arguments = Array(words.dropFirst())
    let options: Options
    switch program {
    case "head", "tail": options = .headTail
    case "sort": options = .sort
    case "uniq": options = .uniq
    case "wc": options = .wc
    case "cut": options = .cut
    case "grep", "egrep": options = .grepFilter
    default: return false
    }
    guard let parsed = parse(arguments, options) else { return false }
    if program == "grep" || program == "egrep" {
      // Exactly one pattern, and no file to read instead of the input.
      return parsed.patterns.count + parsed.operands.count == 1
    }
    return parsed.patterns.isEmpty && parsed.operands.isEmpty
  }

  /// A program the shell finds by name, not one given by its path.
  private static func isProgramName(_ word: String) -> Bool {
    !word.isEmpty && !word.contains("/")
  }

  /// `operand` as a plain path read in `folder`, or nil when it is not one:
  /// standard input (`-`), an option-like name, a pattern the shell or the
  /// tool would expand, a control character, another user's home, a device
  /// or process file, or a parent folder that cannot be resolved.
  private static func path(_ operand: String, in folder: String?) -> String? {
    guard !operand.isEmpty, !operand.hasPrefix("-"),
          !operand.contains(where: { "*?[]{}".contains($0) || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }),
          !operand.hasPrefix("~") || operand == "~" || operand.hasPrefix("~/") else { return nil }
    let joined = join(folder, operand)
    if joined.hasPrefix("/") {
      let resolved = (joined as NSString).standardizingPath
      guard !["/dev", "/proc"].contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else { return nil }
    } else if joined.split(separator: "/").contains("..") {
      return nil
    }
    return joined
  }

  // MARK: Words

  private enum Word: Equatable {
    case word(String)
    case control(String)
  }

  /// Shell words, with quotes removed, and the control operators between
  /// them. Nil for anything this does not read plainly: substitutions,
  /// redirections, variables, globs, comments, unbalanced quotes, background
  /// jobs.
  private static func words(_ command: String) -> [Word]? {
    var result: [Word] = []
    var current = ""
    var inWord = false
    var characters = Array(command)[...]
    func flush() {
      if inWord { result.append(.word(current)) }
      current = ""
      inWord = false
    }
    while let character = characters.popFirst() {
      switch character {
      case "'":
        guard let end = characters.firstIndex(of: "'") else { return nil }
        current += String(characters[..<end])
        characters = characters[characters.index(after: end)...]
        inWord = true
      case "\"":
        guard let end = characters.firstIndex(of: "\"") else { return nil }
        let quoted = String(characters[..<end])
        if quoted.contains("$") || quoted.contains("`") || quoted.contains("\\") || quoted.contains("!") { return nil }
        current += quoted
        characters = characters[characters.index(after: end)...]
        inWord = true
      case "\\":
        guard let next = characters.popFirst(), next != "\n" else { return nil }
        current.append(next)
        inWord = true
      case " ", "\t":
        flush()
      case "|":
        flush()
        if characters.first == "|" { characters.removeFirst(); result.append(.control("||")) }
        else { result.append(.control("|")) }
      case "&":
        flush()
        guard characters.first == "&" else { return nil }
        characters.removeFirst()
        result.append(.control("&&"))
      case ";", "\n", "\r\n":
        flush()
        result.append(.control(";"))
      case "#" where !inWord:
        // A comment, or the rest of the line hidden from a reader.
        return nil
      case "$", "`", ">", "<", "(", ")", "{", "}", "*", "?", "[", "]", "!":
        return nil
      default:
        current.append(character)
        inWord = true
      }
    }
    flush()
    // An assignment in front (`FOO=1 grep …`) changes what runs.
    if case .word(let first) = result.first, first.contains("=") { return nil }
    return result
  }

  private static func join(_ folder: String?, _ path: String) -> String {
    guard let folder, !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
    if path == "." || path == "./" { return folder }
    let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    return (folder.hasSuffix("/") ? folder : folder + "/") + trimmed
  }
}
