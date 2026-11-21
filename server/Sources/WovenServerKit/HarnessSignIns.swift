import Foundation
import WovenProtocol

// Harness CLIs' own sign-ins on this machine: the catalog's sign-in and
// sign-out commands, run by this server, with the link and code they print
// passed on to the UI. The CLIs keep their sign-ins themselves.

/// Runs `command` with `/bin/sh`, the CLI's own folder first on the path, so the
/// catalog's bare command names are the CLI this server found.
func harnessShell(_ command: String, cli: String, input: URL? = nil,
                  timeout: Duration = .seconds(60)) async -> (status: Int32, output: String, errors: String) {
  await ChildProcess.run("/bin/sh", ["-c", command], environment: harnessEnvironment(cli: cli), input: input, timeout: timeout)
}

private func harnessEnvironment(cli: String) -> [String: String] {
  let folder = URL(fileURLWithPath: cli).deletingLastPathComponent().path
  let path = ChildProcess.searchPath(ProcessInfo.processInfo.environment["PATH"])
  // The UI shows the link; the CLI never opens a browser on the server's machine.
  return ["PATH": "\(folder):\(path)", "BROWSER": "/usr/bin/false", "NO_OPEN_BROWSER": "1"]
}

/// The account a status command names, when it names one (Claude Code's JSON).
func reportedAccounts(_ kind: RuntimeKind, _ output: String) -> [RuntimeAccount] {
  guard kind == .claudeCode, let data = output.data(using: .utf8),
        let json = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [] }
  let name = json["email"]?.string ?? json["apiKeyName"]?.string
  switch json["authMethod"]?.string {
  case "claude.ai": return [RuntimeAccount(method: "Claude subscription", name: name)]
  case "api_key", "apiKey", "api-key": return [RuntimeAccount(method: "API key", name: name)]
  default: return []
  }
}

/// A harness's sign-in on this machine, for `StartSignIn` with a runtime.
/// Events carry the link and code the command prints; answers (a code from
/// the sign-in page) go to its standard input.
func harnessSignIn(_ request: StartSignIn, answers: AsyncStream<(id: String, answer: String)>)
  throws -> AsyncThrowingStream<SignInEvent, any Error> {
  guard let runtime = request.runtime, let harness = Harness.named(runtime),
        let method = harness.authentication?.methods?.first(where: { $0.id == request.signInMethod }) else {
    throw ProtocolError(.badRequest, "\(request.runtime?.rawValue ?? request.provider) has no such sign-in.")
  }
  guard let cli = (harness.cliCommand ?? harness.command).nilIfEmpty.flatMap({ ChildProcess.find($0) }) else {
    throw ProtocolError(.failed, "\(harness.displayName) is not installed on this machine.")
  }
  var environment = harnessEnvironment(cli: cli)
  var command = method.command
  if method.inputSecret == true {
    guard let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
      throw ProtocolError(.badRequest, "This sign-in needs a key.")
    }
    // The key reaches the command on its standard input, never its arguments.
    environment["WOVEN_SIGN_IN_KEY"] = key
    command = #"printf '%s\n' "$WOVEN_SIGN_IN_KEY" | "# + command
  }
  let marker = "woven-sign-in-exit"
  let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "\(command) 2>&1; echo \"\(marker) $?\""],
                                 directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: environment)
  let (events, continuation) = AsyncThrowingStream<SignInEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
  let name = harness.displayName
  let reader = Task {
    var output = ""
    var shown: SignInLink?
    var status: Int32?
    for await line in process.lines {
      if line.hasPrefix(marker + " ") {
        status = Int32(line.dropFirst(marker.count + 1).trimmingCharacters(in: .whitespaces))
        continue
      }
      output = String((output + line + "\n").suffix(8000))
      if let link = SignInLink(output), link != shown {
        shown = link
        continuation.yield(.open(url: link.url, code: link.code, instructions: nil))
      }
    }
    if status == 0 {
      continuation.yield(.finished(SignIn(provider: runtime.rawValue, name: name, kind: .subscription, connected: true)))
    } else if !Task.isCancelled {
      let tail = SignInLink.sanitized(output).trimmingCharacters(in: .whitespacesAndNewlines).suffix(1500)
      continuation.yield(.failed(message: tail.isEmpty ? "\(name)'s sign-in did not finish." : String(tail)))
    }
    continuation.finish()
  }
  let answering = Task {
    for await answer in answers { process.send(answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  continuation.onTermination = { _ in
    reader.cancel()
    answering.cancel()
    Task { await process.stop() }
  }
  return events
}

/// Signs a harness out on this machine with the catalog's command; for
/// OpenCode, removes one saved account (`credential` is "integration credential").
func harnessSignOut(_ runtime: RuntimeKind, credential: String?) async throws {
  guard let harness = Harness.named(runtime),
        let cli = (harness.cliCommand ?? harness.command).nilIfEmpty.flatMap({ ChildProcess.find($0) }) else {
    throw ProtocolError(.failed, "\(runtime.rawValue) is not installed on this machine.")
  }
  let result: (status: Int32, output: String, errors: String)
  if runtime == .openCode {
    let parts = (credential ?? "").split(separator: " ").map(String.init)
    guard parts.count == 2 else { throw ProtocolError(.badRequest, "Name the OpenCode account to remove.") }
    result = await ChildProcess.run(cli, ["auth", "logout", "--standalone", parts[0], parts[1]],
                                    environment: harnessEnvironment(cli: cli), timeout: .seconds(30))
  } else {
    guard let command = harness.authentication?.signOutCommand else {
      throw ProtocolError(.badRequest, "\(harness.displayName) has no sign-out.")
    }
    result = await harnessShell(command, cli: cli, timeout: .seconds(30))
  }
  guard result.status == 0 else {
    throw ProtocolError(.failed, "\(harness.displayName) could not sign out: \(result.output.suffix(1000))")
  }
}

/// The first HTTPS link and the one-time code in a sign-in command's output.
struct SignInLink: Equatable {
  var url: String
  var code: String?

  init?(_ output: String) {
    let text = Self.sanitized(output)
    let urls = Self.matches(#"https?://[^\s<>"']+"#, in: text)
      .map { $0.replacingOccurrences(of: #"[),.;]+$"#, with: "", options: .regularExpression) }
      .compactMap { URL(string: $0) }
      .filter { $0.scheme == "https" && $0.host != nil }
    guard let first = urls.first else { return nil }
    let urlCode = urls.lazy.compactMap { url in
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "user_code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }.first
    url = first.absoluteString
    code = urlCode ?? Self.promptedCode(text) ?? Self.labeledCode(text)
  }

  /// Output without terminal escapes or control characters.
  static func sanitized(_ output: String) -> String {
    output
      .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
      .unicodeScalars.filter { $0 == "\n" || $0 == "\t" || (0x20...0x7E).contains($0.value) }
      .reduce(into: "") { $0.unicodeScalars.append($1) }
  }

  private static func labeledCode(_ text: String) -> String? {
    let pattern = #"(?:one[- ]time|device|authorization|confirm\s+this)?\s*code(?:\s+in\s+your\s+browser)?(?:\s+is)?\s*[:\-]?\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return normalizedCode(String(text[range]))
  }

  private static func promptedCode(_ text: String) -> String? {
    let lines = text.components(separatedBy: .newlines)
    let label = #"\b(?:(?:one[- ]time|device|authorization|confirmation)\s+)?code\b"#
    for (index, line) in lines.enumerated()
    where line.range(of: label, options: [.regularExpression, .caseInsensitive]) != nil {
      for offset in 1...3 where index + offset < lines.count {
        if let code = normalizedCode(lines[index + offset]) { return code }
      }
    }
    return nil
  }

  private static func normalizedCode(_ value: String) -> String? {
    let candidate = value.trimmingCharacters(in: .whitespaces)
    guard candidate.range(of: #"^[A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*$"#, options: .regularExpression) != nil,
          !["AUTHORIZATION", "CONFIRMATION", "CONTINUE", "BROWSER", "DEVICE", "LOGIN", "OPENAI", "CHATGPT"].contains(candidate)
    else { return nil }
    return candidate
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
