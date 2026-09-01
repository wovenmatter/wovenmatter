import Darwin
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

enum ProviderLimitCollector {
  static func placeholderAccounts(
    enabledProviders: Set<ProviderKind> = [],
    now: Date
  ) -> [UsageLimitAccount] {
    ProviderKind.supportedAccounts.map { provider in
      UsageLimitAccount(
        provider: provider,
        accountLabel: provider.displayName,
        status: enabledProviders.contains(provider)
          ? .needsCredential : .unavailable,
        source: enabledProviders.contains(provider)
          ? "Ready to check" : "Not enabled",
        detail: enabledProviders.contains(provider)
          ? "Refresh the Usage limits page to check this account."
          : "Enable this account before Woven Matter checks its credentials or usage.",
        observedAt: now
      )
    }
  }

  static func collect(
    homeDirectory: URL,
    openRouterAPIKey: String?,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) async -> [UsageLimitAccount] {
    let disabled = placeholderAccounts(
      enabledProviders: enabledProviders,
      now: now
    ).filter { !enabledProviders.contains($0.provider) }
    let enabled = await withTaskGroup(
      of: UsageLimitAccount.self,
      returning: [UsageLimitAccount].self
    ) { group in
      for provider in ProviderKind.supportedAccounts
        where enabledProviders.contains(provider) {
        group.addTask {
          switch provider {
          case .codex:
            await codex(now: now)
          case .claude:
            await claude(now: now)
          case .grok:
            await grok(now: now)
          case .cursor:
            await cursor(homeDirectory: homeDirectory, now: now)
          case .openCodeGo:
            OpenCodeGoLimitReader(homeDirectory: homeDirectory).account(now: now)
          case .openRouter:
            await openRouter(apiKey: openRouterAPIKey, now: now)
          case .unknown:
            unavailable(.unknown, detail: "This provider is unavailable.", now: now)
          }
        }
      }
      var accounts: [UsageLimitAccount] = []
      for await account in group { accounts.append(account) }
      return accounts
    }
    let accountsByProvider = Dictionary(
      uniqueKeysWithValues: (disabled + enabled).map { ($0.provider, $0) }
    )
    return ProviderKind.supportedAccounts.compactMap { accountsByProvider[$0] }
  }

  private static func codex(now: Date) async -> UsageLimitAccount {
    guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "codex") else {
      return unavailable(.codex, detail: "Codex CLI is not installed.", now: now)
    }
    do {
      let responses = try await JSONRPCUsageCommand.run(
        executable: executable,
        arguments: ["-s", "read-only", "-a", "never", "app-server"],
        messages: [
          ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "wovenmatter-macos", "version": "1"]
          ]],
          ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
          ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]],
          ["jsonrpc": "2.0", "id": 3, "method": "account/read", "params": [:]],
        ],
        timeout: .seconds(8)
      )
      let limits = try responseResult(responses, id: 2)
      let account = try? responseResult(responses, id: 3)
      let rateLimits = dictionary(limits["rateLimits"] ?? limits["rate_limits"])
      let identity = dictionary(account?["account"])
      let email = string(identity?["email"])
      let plan = string(identity?["planType"] ?? identity?["plan_type"]
        ?? rateLimits?["planType"] ?? rateLimits?["plan_type"])
      var windows: [ProviderQuotaWindow] = []
      if let value = quotaWindow(rateLimits?["primary"], id: "five-hour", label: "Five-hour") {
        windows.append(value)
      }
      if let value = quotaWindow(rateLimits?["secondary"], id: "weekly", label: "Weekly") {
        windows.append(value)
      }
      if let additional = dictionary(limits["rateLimitsByLimitId"] ?? limits["rate_limits_by_limit_id"]) {
        for (key, raw) in additional.sorted(by: { $0.key < $1.key }) {
          guard let value = dictionary(raw) else { continue }
          let label = string(value["limitName"] ?? value["limit_name"]) ?? key
          if let window = quotaWindow(value["primary"], id: "\(key)-primary", label: label) {
            windows.append(window)
          }
          if let window = quotaWindow(value["secondary"], id: "\(key)-secondary", label: "\(label) weekly") {
            windows.append(window)
          }
        }
      }
      let signedIn = identity != nil || plan != nil
      return UsageLimitAccount(
        provider: .codex,
        accountLabel: email ?? plan ?? "Codex account",
        status: windows.isEmpty ? (signedIn ? .signedIn : .unavailable) : .available,
        quotaWindows: windows,
        source: "Codex app-server",
        detail: windows.isEmpty
          ? "Codex account state was available, but the CLI returned no numeric quota windows."
          : "Live account limits returned by the locally signed-in Codex CLI.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.codex
      )
    } catch {
      return codexLocalSignIn(now: now) ?? failed(
        .codex,
        detail: "Codex account limits could not be read from the local CLI.",
        now: now
      )
    }
  }

  private static func claude(now: Date) async -> UsageLimitAccount {
    guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "claude") else {
      return unavailable(.claude, detail: "Claude CLI is not installed.", now: now)
    }
    do {
      let result = try await BoundedUsageCommand.run(
        executable: executable,
        arguments: ["auth", "status", "--json"],
        maximumBytes: 256 * 1_024,
        timeout: .seconds(8)
      )
      let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
      let loggedIn = boolean(object?["loggedIn"] ?? object?["logged_in"]) ?? false
      let email = string(object?["email"])
      let method = string(object?["authMethod"] ?? object?["auth_method"])
      return UsageLimitAccount(
        provider: .claude,
        accountLabel: email ?? "Claude account",
        status: loggedIn ? .signedIn : .needsCredential,
        source: "Claude CLI auth status",
        detail: loggedIn
          ? "Signed in via \(method ?? "Claude CLI"). Claude does not expose numeric consumer limits through its noninteractive CLI, so Woven Matter does not infer them."
          : "Claude CLI is installed but not signed in.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.claude
      )
    } catch {
      return failed(.claude, detail: "Claude sign-in state could not be read from the local CLI.", now: now)
    }
  }

  private static func grok(now: Date) async -> UsageLimitAccount {
    guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "grok") else {
      return unavailable(.grok, detail: "Grok CLI is not installed.", now: now)
    }
    do {
      let responses = try await JSONRPCUsageCommand.run(
        executable: executable,
        arguments: ["agent", "stdio"],
        messages: [
          ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "1",
            "clientCapabilities": [
              "fs": ["readTextFile": false, "writeTextFile": false],
              "terminal": false,
            ],
          ]],
          ["jsonrpc": "2.0", "id": 2, "method": "x.ai/billing", "params": [:]],
        ],
        timeout: .seconds(6)
      )
      let billing = try responseResult(responses, id: 2)
      let usage = dictionary(billing["usage"])
      let limitCents = integer(dictionary(billing["monthlyLimit"])?["val"])
      let usedCents = integer(dictionary(usage?["totalUsed"])?["val"])
      let cycle = dictionary(billing["billingCycle"])
      let startsAt = parseDate(string(cycle?["billingPeriodStart"]))
      let endsAt = parseDate(string(cycle?["billingPeriodEnd"]))
      let percent = limitCents.flatMap { limit -> Double? in
        guard limit > 0, let usedCents else { return nil }
        return min(100, max(0, Double(usedCents) / Double(limit) * 100))
      }
      let duration: Int? = if let startsAt, let endsAt, endsAt > startsAt {
        Int(endsAt.timeIntervalSince(startsAt) / 60)
      } else {
        nil
      }
      let windows = percent.map {
        [ProviderQuotaWindow(
          id: "billing-cycle",
          label: "Monthly credits",
          usedPercent: $0,
          usageKnown: true,
          windowMinutes: duration,
          resetsAt: endsAt
        )]
      } ?? []
      let providerBudget: ProviderReportedBudget? = if let usedCents, let limitCents {
        ProviderReportedBudget(
          usedMicros: usedCents * 10_000,
          limitMicros: limitCents * 10_000,
          currency: "USD",
          period: "monthly",
          resetsAt: endsAt,
          scope: "account"
        )
      } else {
        nil
      }
      return UsageLimitAccount(
        provider: .grok,
        accountLabel: "Grok account",
        status: windows.isEmpty ? .signedIn : .available,
        quotaWindows: windows,
        providerBudget: providerBudget,
        source: "Grok CLI billing RPC",
        detail: windows.isEmpty
          ? "Grok is reachable, but the signed-in account returned no numeric billing limit."
          : "Live billing-cycle credits returned by the locally signed-in Grok CLI.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.grok
      )
    } catch {
      return grokLocalSignIn(now: now) ?? failed(
        .grok,
        detail: "Grok account billing was unavailable. Sign in with the Grok CLI to enable it.",
        now: now
      )
    }
  }

  private static func codexLocalSignIn(now: Date) -> UsageLimitAccount? {
    let environment = ProcessInfo.processInfo.environment
    let codexHome: URL
    if let configured = string(environment["CODEX_HOME"]) {
      codexHome = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    } else {
      codexHome = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex", directoryHint: .isDirectory)
    }
    guard let root = try? localJSONObject(
      at: codexHome.appending(path: "auth.json"),
      maximumBytes: 1_048_576
    ), let tokens = dictionary(root["tokens"]),
      string(tokens["access_token"] ?? tokens["accessToken"]) != nil
    else { return nil }
    return UsageLimitAccount(
      provider: .codex,
      accountLabel: "Codex account",
      status: .signedIn,
      source: "Codex local sign-in",
      detail: "Signed in locally. The Codex CLI did not return numeric quota windows during this refresh.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.codex
    )
  }

  private static func grokLocalSignIn(now: Date) -> UsageLimitAccount? {
    let environment = ProcessInfo.processInfo.environment
    let grokHome: URL
    if let configured = string(environment["GROK_HOME"]) {
      grokHome = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    } else {
      grokHome = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".grok", directoryHint: .isDirectory)
    }
    guard let root = try? localJSONObject(
      at: grokHome.appending(path: "auth.json"),
      maximumBytes: 1_048_576
    ) else { return nil }
    let entries = root.compactMap { scope, raw -> (String, [String: Any])? in
      guard let entry = dictionary(raw), string(entry["key"]) != nil else { return nil }
      return (scope, entry)
    }
    guard let entry = entries.first(where: { $0.0.hasPrefix("https://auth.x.ai::") })?.1
      ?? entries.first(where: { $0.0.contains("/sign-in") })?.1
    else { return nil }
    let firstName = string(entry["first_name"])
    let lastName = string(entry["last_name"])
    let displayName = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    return UsageLimitAccount(
      provider: .grok,
      accountLabel: string(entry["email"]) ?? string(displayName) ?? "Grok account",
      status: .signedIn,
      source: "Grok local sign-in",
      detail: "Signed in locally. This Grok CLI version did not expose a numeric billing window during this refresh.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.grok
    )
  }

  private static func cursor(
    homeDirectory: URL,
    now: Date
  ) async -> UsageLimitAccount {
    if let account = try? await CursorAccountClient(homeDirectory: homeDirectory).limits(now: now) {
      return account
    }
    guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "cursor-agent") else {
      return unavailable(.cursor, detail: "Cursor Agent CLI is not installed.", now: now)
    }
    let probe = await Task.detached {
      CursorACPSupport.probeAbout(executable: executable)
    }.value
    switch probe.auth {
    case .authenticated(let email):
      return UsageLimitAccount(
        provider: .cursor,
        accountLabel: email ?? "Cursor account",
        status: .signedIn,
        source: "Cursor Agent CLI",
        detail: "Signed in locally, but Cursor's account usage APIs were unavailable during this refresh.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.cursor
      )
    case .unauthenticated:
      return UsageLimitAccount(
        provider: .cursor,
        accountLabel: "Cursor account",
        status: .needsCredential,
        source: "Cursor Agent CLI",
        detail: "Cursor Agent is installed but not signed in.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.cursor
      )
    case .unknown:
      return failed(.cursor, detail: probe.message ?? "Cursor sign-in state could not be verified.", now: now)
    }
  }

  private static func openRouter(apiKey: String?, now: Date) async -> UsageLimitAccount {
    guard let apiKey, !apiKey.isEmpty else {
      return UsageLimitAccount(
        provider: .openRouter,
        accountLabel: "OpenRouter API key",
        status: .needsCredential,
        source: "OpenRouter API",
        detail: "Add an OpenRouter API or management key to retrieve its credit and key limits. The key stays in this Mac's Keychain.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.openRouter
      )
    }
    do {
      async let keyResponse = openRouterRequest(path: "key", apiKey: apiKey)
      async let creditsResponse = openRouterRequest(path: "credits", apiKey: apiKey)
      let keyObject = try? await keyResponse
      let creditsObject = try? await creditsResponse
      guard keyObject != nil || creditsObject != nil else {
        throw ProviderLimitCollectorError.invalidResponse
      }
      let keyData = dictionary(keyObject?["data"]) ?? keyObject
      let creditData = dictionary(creditsObject?["data"]) ?? creditsObject
      let limit = number(keyData?["limit"])
      let usage = number(keyData?["usage"])
        ?? number(creditData?["total_usage"] ?? creditData?["totalUsage"])
      let totalCredits = number(creditData?["total_credits"] ?? creditData?["totalCredits"])
      let remaining = number(keyData?["limit_remaining"] ?? keyData?["limitRemaining"])
        ?? (totalCredits.flatMap { total in usage.map { max(0, total - $0) } })
      let reset = string(keyData?["limit_reset"] ?? keyData?["limitReset"])
      let budget: ProviderReportedBudget? = if let limit, limit > 0, let usage {
        ProviderReportedBudget(
          usedMicros: micros(usage),
          limitMicros: micros(limit),
          currency: "USD",
          period: reset,
          resetsAt: nil,
          scope: "api-key"
        )
      } else if let totalCredits, let usage {
        ProviderReportedBudget(
          usedMicros: micros(usage),
          limitMicros: micros(totalCredits),
          currency: "USD",
          period: "lifetime credits",
          resetsAt: nil,
          scope: "account"
        )
      } else {
        nil
      }
      return UsageLimitAccount(
        provider: .openRouter,
        accountLabel: string(keyData?["label"] ?? keyData?["name"]) ?? "OpenRouter API key",
        status: .available,
        balance: remaining.map { ProviderMoney(amountMicros: micros($0), currency: "USD") },
        providerBudget: budget,
        source: "OpenRouter credits and key APIs",
        detail: "Live OpenRouter key allowance and credits. Management-key-only fields appear when the stored credential has that scope.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.openRouter
      )
    } catch {
      return failed(.openRouter, detail: "OpenRouter rejected the stored key or did not return credit data.", now: now)
    }
  }

  private static func openRouterRequest(path: String, apiKey: String) async throws -> [String: Any] {
    guard let url = URL(string: "https://openrouter.ai/api/v1/\(path)") else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await BoundedHTTPResponse.data(
      for: request,
      using: .shared,
      maximumBytes: 1_048_576
    )
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    return object
  }

  private static func localJSONObject(at url: URL, maximumBytes: Int) throws -> [String: Any] {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= maximumBytes,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    return object
  }

  private static func quotaWindow(
    _ raw: Any?,
    id: String,
    label: String
  ) -> ProviderQuotaWindow? {
    guard let value = dictionary(raw),
          let used = number(value["usedPercent"] ?? value["used_percent"]),
          used >= 0, used <= 100 else { return nil }
    let minutes = integer(value["windowDurationMins"] ?? value["window_duration_mins"])
      .flatMap(Int.init(exactly:))
      ?? integer(value["limitWindowSeconds"] ?? value["limit_window_seconds"])
        .flatMap(Int.init(exactly:))
        .map { $0 / 60 }
    let reset = integer(value["resetsAt"] ?? value["resets_at"] ?? value["reset_at"])
      .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    return ProviderQuotaWindow(
      id: id,
      label: label,
      usedPercent: used,
      usageKnown: true,
      windowMinutes: minutes,
      resetsAt: reset
    )
  }

  private static func responseResult(_ responses: [[String: Any]], id: Int64) throws -> [String: Any] {
    guard let message = responses.first(where: { integer($0["id"]) == id }),
          message["error"] == nil,
          let result = dictionary(message["result"]) else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    return result
  }

  private static func unavailable(
    _ provider: ProviderKind,
    detail: String,
    now: Date
  ) -> UsageLimitAccount {
    UsageLimitAccount(
      provider: provider,
      accountLabel: provider.displayName,
      status: .unavailable,
      source: "Local CLI",
      detail: detail,
      observedAt: now
    )
  }

  private static func failed(
    _ provider: ProviderKind,
    detail: String,
    now: Date
  ) -> UsageLimitAccount {
    UsageLimitAccount(
      provider: provider,
      accountLabel: provider.displayName,
      status: .failed,
      source: "Local account probe",
      detail: detail,
      observedAt: now
    )
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  private static func number(_ value: Any?) -> Double? {
    let result: Double?
    if let value = value as? NSNumber { result = value.doubleValue }
    else if let value = value as? String { result = Double(value) }
    else { result = nil }
    return result.flatMap { $0.isFinite ? $0 : nil }
  }
  private static func integer(_ value: Any?) -> Int64? {
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
  }
  private static func boolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }
  private static func micros(_ dollars: Double) -> Int64 {
    guard dollars.isFinite else { return 0 }
    let maximum = Double(Int64.max) / 1_000_000
    return Int64(min(maximum, max(0, dollars)) * 1_000_000)
  }
  private static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

enum ProviderDashboardURL {
  static let codex = URL(string: "https://chatgpt.com/codex/settings/usage")
  static let claude = URL(string: "https://claude.ai/settings/usage")
  static let grok = URL(string: "https://grok.com/?_s=usage")
  static let cursor = URL(string: "https://cursor.com/dashboard?tab=usage")
  static let openCodeGo = URL(string: "https://opencode.ai/auth")
  static let openRouter = URL(string: "https://openrouter.ai/settings/credits")
}

private enum JSONRPCUsageCommand {
  static func run(
    executable: URL,
    arguments: [String],
    messages: [[String: Any]],
    timeout: Duration
  ) async throws -> [[String: Any]] {
    let frames = try messages.map { message -> JSONRPCUsageFrame in
      var data = try JSONSerialization.data(
        withJSONObject: message,
        options: [.withoutEscapingSlashes]
      )
      data.append(0x0A)
      return JSONRPCUsageFrame(
        data: data,
        expectedResponseID: (message["id"] as? NSNumber)?.int64Value
      )
    }
    let command = SequentialJSONRPCProcess()
    let output = try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: JSONRPCRaceResult.self) { group in
        group.addTask {
          .output(try command.run(
            executable: executable,
            arguments: arguments,
            frames: frames,
            maximumBytes: 1_048_576
          ))
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          command.terminate()
          return .timedOut
        }
        guard let result = try await group.next() else {
          throw ProviderLimitCollectorError.commandFailed
        }
        group.cancelAll()
        command.terminate()
        switch result {
        case .output(let data): return data
        case .timedOut: throw ProviderLimitCollectorError.commandTimedOut
        }
      }
    } onCancel: {
      command.terminate()
    }
    return output.split(separator: 0x0A).compactMap {
      try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
    }
  }
}

private struct JSONRPCUsageFrame: Sendable {
  let data: Data
  let expectedResponseID: Int64?
}

private enum JSONRPCRaceResult: Sendable {
  case output(Data)
  case timedOut
}

private final class SequentialJSONRPCProcess: @unchecked Sendable {
  private let command = UsageCommandProcess()

  func run(
    executable: URL,
    arguments: [String],
    frames: [JSONRPCUsageFrame],
    maximumBytes: Int
  ) throws -> Data {
    let process = command.process
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.executableURL = executable
    process.arguments = arguments
    process.environment = usageCommandEnvironment()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? outputPipe.fileHandleForWriting.close()
    defer {
      try? inputPipe.fileHandleForWriting.close()
      command.terminate()
    }

    var buffer = Data()
    var captured = Data()
    var pending: [[String: Any]] = []
    for frame in frames {
      try inputPipe.fileHandleForWriting.write(contentsOf: frame.data)
      guard let expectedID = frame.expectedResponseID else { continue }
      while !pending.contains(where: { Self.identifier($0["id"]) == expectedID }) {
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          guard !line.isEmpty else { continue }
          captured.append(line)
          captured.append(0x0A)
          guard captured.count <= maximumBytes else {
            throw ProviderLimitCollectorError.outputTooLarge
          }
          if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            pending.append(object)
          }
        }
        if pending.contains(where: { Self.identifier($0["id"]) == expectedID }) { break }
        guard let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024),
              !chunk.isEmpty else {
          throw ProviderLimitCollectorError.commandFailed
        }
        buffer.append(chunk)
        guard buffer.count + captured.count <= maximumBytes else {
          throw ProviderLimitCollectorError.outputTooLarge
        }
      }
    }
    return captured
  }

  func terminate() {
    command.terminate()
  }

  private static func identifier(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
  }
}

private enum BoundedUsageCommand {
  struct Result: Sendable {
    let stdout: Data
  }

  static func run(
    executable: URL,
    arguments: [String],
    input: Data = Data(),
    maximumBytes: Int,
    timeout: Duration,
    expectedResponseIDs: Set<Int64> = []
  ) async throws -> Result {
    let command = UsageCommandProcess()
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Result.self) { group in
        let process = command.process
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = usageCommandEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? outputPipe.fileHandleForWriting.close()
        inputPipe.fileHandleForWriting.write(input)
        try? inputPipe.fileHandleForWriting.close()

        group.addTask {
          var output = Data()
          while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024),
                !chunk.isEmpty {
            output.append(chunk)
            guard output.count <= maximumBytes else {
              command.terminate()
              throw ProviderLimitCollectorError.outputTooLarge
            }
            if !expectedResponseIDs.isEmpty,
               expectedResponseIDs.isSubset(of: responseIDs(in: output)) {
              command.terminate()
              return Result(stdout: output)
            }
          }
          return Result(stdout: output)
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          command.terminate()
          throw ProviderLimitCollectorError.commandTimedOut
        }
        guard let result = try await group.next() else {
          throw ProviderLimitCollectorError.commandFailed
        }
        group.cancelAll()
        command.terminate()
        return result
      }
    } onCancel: {
      command.terminate()
    }
  }

  private static func responseIDs(in data: Data) -> Set<Int64> {
    Set(data.split(separator: 0x0A).compactMap { line in
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
      else { return nil }
      return (object["id"] as? NSNumber)?.int64Value
    })
  }

}

private func usageCommandEnvironment() -> [String: String] {
  let inherited = ProcessInfo.processInfo.environment
  let allowed = [
    "PATH", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME", "SHELL", "HOME",
    "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
  ]
  var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
    inherited[key].map { (key, $0) }
  })
  result["NO_COLOR"] = "1"
  result["TERM"] = "dumb"
  return result
}

private final class UsageCommandProcess: @unchecked Sendable {
  let process = Process()
  private let lock = NSLock()

  func terminate() {
    lock.withLock {
      guard process.isRunning else { return }
      let identifier = process.processIdentifier
      process.terminate()
      if process.isRunning { kill(identifier, SIGKILL) }
    }
  }
}

private struct OpenCodeGoLimitReader {
  private struct Row {
    let createdAt: Date
    let cost: Double
  }

  let homeDirectory: URL

  func account(now: Date) -> UsageLimitAccount {
    let root = homeDirectory.appending(path: ".local/share/opencode", directoryHint: .isDirectory)
    let authURL = root.appending(path: "auth.json")
    let databaseURL = root.appending(path: "opencode.db")
    let authenticated = hasAuthKey(at: authURL)
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      return UsageLimitAccount(
        provider: .openCodeGo,
        accountLabel: "OpenCode Go",
        status: authenticated ? .signedIn : .unavailable,
        source: "OpenCode local history",
        detail: authenticated
          ? "OpenCode Go is configured, but its local usage database was not found."
          : "OpenCode Go was not detected.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.openCodeGo
      )
    }
    guard let rows = try? readRows(databaseURL), authenticated || !rows.isEmpty else {
      return UsageLimitAccount(
        provider: .openCodeGo,
        accountLabel: "OpenCode Go",
        status: .unavailable,
        source: "OpenCode local history",
        detail: "OpenCode Go was not detected in local authentication or usage history.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.openCodeGo
      )
    }
    guard !rows.isEmpty else {
      return UsageLimitAccount(
        provider: .openCodeGo,
        accountLabel: "OpenCode Go",
        status: .signedIn,
        source: "OpenCode local history",
        detail: "OpenCode Go is configured. Usage totals will appear after local usage is recorded.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.openCodeGo
      )
    }

    let fiveHourStart = now.addingTimeInterval(-5 * 60 * 60)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    utc.firstWeekday = 2
    utc.minimumDaysInFirstWeek = 4
    let weekComponents = utc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
    let weekStart = utc.date(from: weekComponents) ?? now
    let weekEnd = utc.date(byAdding: .day, value: 7, to: weekStart) ?? now
    let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
    let monthEnd = utc.date(byAdding: .month, value: 1, to: monthStart) ?? now
    let fiveHourRows = rows.filter { $0.createdAt >= fiveHourStart && $0.createdAt <= now }
    let usedFive = fiveHourRows.reduce(0) { $0 + $1.cost }
    let usedWeek = rows.filter { $0.createdAt >= weekStart && $0.createdAt < weekEnd }
      .reduce(0) { $0 + $1.cost }
    let usedMonth = rows.filter { $0.createdAt >= monthStart && $0.createdAt < monthEnd }
      .reduce(0) { $0 + $1.cost }
    return UsageLimitAccount(
      provider: .openCodeGo,
      accountLabel: "OpenCode Go",
      status: .signedIn,
      source: "OpenCode local cost history",
      detail: "Local records report \(money(usedFive)) in the last five hours, \(money(usedWeek)) this UTC week, and \(money(usedMonth)) this UTC month. OpenCode Go did not expose live remaining counters, so Woven Matter does not infer an allowance.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.openCodeGo
    )
  }

  private func readRows(_ url: URL) throws -> [Row] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
      sqlite3_close(database)
      throw ProviderLimitCollectorError.invalidResponse
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 250)
    let sql = """
      SELECT COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.time_created),
             CAST(json_extract(p.data, '$.cost') AS REAL)
      FROM part p
      JOIN message m ON m.id = p.message_id
      WHERE json_valid(p.data) AND json_valid(m.data)
        AND json_extract(p.data, '$.type') = 'step-finish'
        AND json_extract(m.data, '$.providerID') = 'opencode-go'
        AND json_type(p.data, '$.cost') IN ('integer', 'real')
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw ProviderLimitCollectorError.invalidResponse }
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let raw = sqlite3_column_int64(statement, 0)
      let cost = sqlite3_column_double(statement, 1)
      guard raw > 0, cost >= 0, cost.isFinite else { continue }
      let seconds = Double(raw) / (raw > 10_000_000_000 ? 1_000 : 1)
      rows.append(Row(createdAt: Date(timeIntervalSince1970: seconds), cost: cost))
    }
    return rows
  }

  private func hasAuthKey(at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["opencode-go"] != nil else { return false }
    return true
  }

  private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
  }
}

private enum ProviderLimitCollectorError: Error {
  case invalidResponse
  case commandFailed
  case commandTimedOut
  case outputTooLarge
}
