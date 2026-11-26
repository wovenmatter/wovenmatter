import Foundation

/// What a shell command did, when it is one of the common read-only forms a
/// file tool also does: a search, a listing or reading one file. Anything
/// else, including several commands joined together, is not recognised, so a
/// row never claims an operation its command did not do.
public enum ConversationShellOperation: Equatable, Sendable {
  case search(pattern: String, path: String?)
  case list(path: String?)
  case read(path: String)

  /// The operation of `command`, run in `folder` when known. A leading
  /// `cd <dir> &&` sets the folder; a pipeline counts as its first command
  /// when everything after it only filters that command's output.
  public static func recognize(_ command: String, folder: String? = nil) -> ConversationShellOperation? {
    guard var words = Self.words(command) else { return nil }
    var folder = folder
    // `cd <dir> &&` (or `;`) in front sets the folder for what follows.
    if words.count > 3, words[0] == .word("cd"), case .word(let dir) = words[1],
       words[2] == .control("&&") || words[2] == .control(";") {
      folder = Self.join(folder, dir)
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
    let program = (words[0] as NSString).lastPathComponent
    let arguments = Array(words.dropFirst())
    func place(_ paths: [String]) -> String?? {
      // One path, or none (the folder itself); more is not one operation.
      guard paths.count <= 1 else { return nil }
      return .some(paths.first.map { join(folder, $0) } ?? folder)
    }
    switch program {
    case "grep", "egrep", "rg", "ag":
      let values: Set<Character> = program == "grep" || program == "egrep" ? ["e", "A", "B", "C", "m", "d", "D"]
        : program == "rg" ? ["e", "g", "t", "T", "A", "B", "C", "m", "M", "j", "E"] : ["e", "A", "B", "C", "G", "m", "g"]
      guard let parsed = parse(arguments, shortValues: values, refusing: ["f", "file", "files", "files-with-matches"]) else { return nil }
      var operands = parsed.operands
      guard let pattern = parsed.pattern ?? (operands.isEmpty ? nil : operands.removeFirst()), !pattern.isEmpty else { return nil }
      // grep with no path reads its input: not a search of files.
      if (program == "grep" || program == "egrep"), operands.isEmpty { return nil }
      guard let path = place(operands) else { return nil }
      return .search(pattern: pattern, path: path)
    case "ls":
      guard let parsed = parse(arguments, shortValues: [], refusing: []), parsed.pattern == nil,
            let path = place(parsed.operands) else { return nil }
      return .list(path: path)
    case "tree":
      guard let parsed = parse(arguments, shortValues: ["L", "I", "P"], refusing: ["o"]), parsed.pattern == nil,
            let path = place(parsed.operands) else { return nil }
      return .list(path: path)
    case "find":
      // Paths come first; the rest are tests, none of which may act.
      let acting: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
      guard !arguments.contains(where: acting.contains) else { return nil }
      let paths = Array(arguments.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" })
      guard let path = place(paths) else { return nil }
      return .list(path: path)
    case "cat", "nl", "wc":
      guard let parsed = parse(arguments, shortValues: [], refusing: []), parsed.pattern == nil,
            parsed.operands.count == 1 else { return nil }
      return .read(path: join(folder, parsed.operands[0]))
    case "head", "tail":
      guard let parsed = parse(arguments, shortValues: ["n", "c"], refusing: ["f", "F", "follow"]),
            parsed.pattern == nil, parsed.operands.count == 1 else { return nil }
      return .read(path: join(folder, parsed.operands[0]))
    case "sed":
      // Only `sed -n '<lines>p' <file>`: printing lines, never editing.
      guard arguments.count == 3, arguments[0] == "-n",
            arguments[1].range(of: #"^(\d+|\$)(,(\d+|\$))?p$"#, options: .regularExpression) != nil,
            !arguments[2].hasPrefix("-") else { return nil }
      return .read(path: join(folder, arguments[2]))
    default:
      return nil
    }
  }

  /// Flags, the pattern given with `-e`, and the operands. Short flags in
  /// `shortValues` take a value (attached or next); `--name value` takes one
  /// for the common long names. A refused flag means nil.
  private static func parse(_ arguments: [String], shortValues: Set<Character>, refusing: Set<String>)
    -> (pattern: String?, operands: [String])? {
    let longValues: Set<String> = ["include", "exclude", "exclude-dir", "glob", "type", "type-not", "max-count",
                                   "context", "after-context", "before-context", "regexp", "ignore-dir", "max-depth"]
    var pattern: String?
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
        let name = String(argument.dropFirst(2).prefix { $0 != "=" })
        if refusing.contains(name) { return nil }
        if !argument.contains("="), longValues.contains(name) {
          guard index < arguments.count else { return nil }
          if name == "regexp" { pattern = arguments[index] }
          index += 1
        } else if name == "regexp" {
          pattern = String(argument.drop { $0 != "=" }.dropFirst())
        }
      } else {
        // A cluster such as -rniw, or -A3, or -e PATTERN.
        let letters = Array(argument.dropFirst())
        if letters.allSatisfy(\.isNumber) { continue }   // head -40
        for (offset, letter) in letters.enumerated() {
          if refusing.contains(String(letter)) { return nil }
          guard shortValues.contains(letter) else { continue }
          let attached = String(letters[(offset + 1)...])
          let value: String
          if attached.isEmpty {
            guard index < arguments.count else { return nil }
            value = arguments[index]
            index += 1
          } else {
            value = attached
          }
          if letter == "e" { pattern = value }
          break
        }
      }
    }
    return (pattern, operands)
  }

  /// A command that only filters what is piped into it.
  private static func isFilter(_ words: [String]) -> Bool {
    let program = (words[0] as NSString).lastPathComponent
    let arguments = Array(words.dropFirst())
    switch program {
    case "head", "tail":
      guard let parsed = parse(arguments, shortValues: ["n", "c"], refusing: ["f", "F", "follow"]) else { return false }
      return parsed.operands.isEmpty
    case "sort", "uniq", "wc":
      guard let parsed = parse(arguments, shortValues: ["k", "t"], refusing: ["o", "output"]) else { return false }
      return parsed.operands.isEmpty
    case "cut":
      guard let parsed = parse(arguments, shortValues: ["d", "f", "c", "b"], refusing: []) else { return false }
      return parsed.operands.isEmpty
    case "grep", "egrep":
      guard let parsed = parse(arguments, shortValues: ["e", "A", "B", "C", "m"], refusing: ["f", "r", "R"]) else { return false }
      return parsed.operands.count == (parsed.pattern == nil ? 1 : 0)
    default:
      return false
    }
  }

  // MARK: Words

  private enum Word: Equatable {
    case word(String)
    case control(String)
  }

  /// Shell words, with quotes removed, and the control operators between
  /// them. Nil for anything this does not read plainly: substitutions,
  /// redirections, variables, unbalanced quotes, background jobs.
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
        characters = characters[(end + 1)...]
        inWord = true
      case "\"":
        guard let end = characters.firstIndex(of: "\"") else { return nil }
        let quoted = String(characters[..<end])
        if quoted.contains("$") || quoted.contains("`") || quoted.contains("\\") { return nil }
        current += quoted
        characters = characters[(end + 1)...]
        inWord = true
      case "\\":
        guard let next = characters.popFirst() else { return nil }
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
      case ";", "\n":
        flush()
        result.append(.control(";"))
      case "$", "`", ">", "<", "(", ")", "{", "}":
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
