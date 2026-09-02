import Darwin
import Foundation
import LocalAuthentication
import Security
import SQLite3
import WovenMatterClient
import WovenMatterCore

struct CodexWorkspaceSource: Sendable {
  let workspace: CodexUsageWorkspace
  let credentialsURL: URL
  let isLive: Bool
}

enum ProviderLimitCollector {
  static func placeholderAccounts(
    enabledProviders: Set<ProviderKind> = Set(ProviderKind.supportedAccounts),
    now: Date
  ) -> [UsageLimitAccount] {
    ProviderKind.supportedAccounts.compactMap { provider in
      guard enabledProviders.contains(provider) else { return nil }
      return UsageLimitAccount(
        provider: provider,
        accountLabel: provider.displayName,
        status: .needsCredential,
        source: "Ready to check",
        detail: "Refresh the Usage limits page to check this account.",
        observedAt: now
      )
    }
  }

  static func collect(
    homeDirectory: URL,
    openRouterAPIKey: String?,
    enabledProviders: Set<ProviderKind>,
    keychainInteraction: UsageKeychainInteraction = .noninteractive,
    codexWorkspaceSource: CodexWorkspaceSource? = nil,
    codexWorkspaceCount: Int = 0,
    now: Date
  ) async -> [UsageLimitAccount] {
    let enabled = await withTaskGroup(
      of: UsageLimitAccount.self,
      returning: [UsageLimitAccount].self
    ) { group in
      for provider in ProviderKind.supportedAccounts
        where enabledProviders.contains(provider) {
        group.addTask {
          switch provider {
          case .codex:
            await codex(
              homeDirectory: homeDirectory,
              workspaceSource: codexWorkspaceSource,
              workspaceCount: codexWorkspaceCount,
              now: now
            )
          case .claude:
            await claude(
              homeDirectory: homeDirectory,
              keychainInteraction: keychainInteraction,
              now: now
            )
          case .grok:
            await grok(homeDirectory: homeDirectory, now: now)
          case .cursor:
            await cursor(homeDirectory: homeDirectory, now: now)
          case .openCodeGo:
            await OpenCodeGoLimitReader(homeDirectory: homeDirectory).account(now: now)
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
      uniqueKeysWithValues: enabled.map { ($0.provider, $0) }
    )
    return ProviderKind.supportedAccounts.compactMap { accountsByProvider[$0] }
  }

  static func codexWorkspaceSources(homeDirectory: URL) -> [CodexWorkspaceSource] {
    var sources = managedCodexWorkspaceSources(homeDirectory: homeDirectory)
    let applicationSupport = homeDirectory.appending(
      path: "Library/Application Support/CodexBar",
      directoryHint: .isDirectory
    )
    let labelsURL = applicationSupport.appending(path: "codex-openai-workspaces.json")
    let labelObject = (try? localJSONObject(at: labelsURL, maximumBytes: 1_048_576)) ?? [:]
    let labels = dictionary(labelObject["labelsByWorkspaceAccountID"]) ?? [:]
    let configured = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }
    let liveCredentialsURL = (configured ?? homeDirectory.appending(path: ".codex"))
      .appending(path: "auth.json")
    if let liveRoot = try? localJSONObject(at: liveCredentialsURL, maximumBytes: 1_048_576),
       let tokens = dictionary(liveRoot["tokens"]),
       let workspaceID = string(tokens["account_id"] ?? tokens["accountId"]
         ?? liveRoot["account_id"] ?? liveRoot["accountId"]) {
      if let index = sources.firstIndex(where: { $0.workspace.id == workspaceID }) {
        let existing = sources[index]
        sources[index] = CodexWorkspaceSource(
          workspace: existing.workspace,
          credentialsURL: liveCredentialsURL,
          isLive: true
        )
      } else {
        let email = codexIdentityEmail(root: liveRoot) ?? "OpenAI account"
        let name = string(labels[workspaceID]) ?? "Current workspace"
        sources.append(CodexWorkspaceSource(
          workspace: CodexUsageWorkspace(id: workspaceID, name: name, email: email),
          credentialsURL: liveCredentialsURL,
          isLive: true
        ))
      }
    }

    var seen = Set<String>()
    return sources
      .filter { seen.insert($0.workspace.id).inserted }
      .sorted {
        if $0.isLive != $1.isLive { return $0.isLive }
        return $0.workspace.selectionLabel.localizedCaseInsensitiveCompare(
          $1.workspace.selectionLabel
        ) == .orderedAscending
      }
  }

  static func codexManagedWorkspaceHomeDirectory(
    homeDirectory: URL,
    workspaceID: String
  ) -> URL? {
    managedCodexWorkspaceSources(homeDirectory: homeDirectory)
      .first { $0.workspace.id == workspaceID }?
      .credentialsURL.deletingLastPathComponent()
  }

  private static func managedCodexWorkspaceSources(
    homeDirectory: URL
  ) -> [CodexWorkspaceSource] {
    let applicationSupport = homeDirectory.appending(
      path: "Library/Application Support/CodexBar",
      directoryHint: .isDirectory
    )
    let managedHomes = applicationSupport.appending(
      path: "managed-codex-homes",
      directoryHint: .isDirectory
    ).standardizedFileURL
    let labelsURL = applicationSupport.appending(path: "codex-openai-workspaces.json")
    let labelObject = (try? localJSONObject(at: labelsURL, maximumBytes: 1_048_576)) ?? [:]
    let labels = dictionary(labelObject["labelsByWorkspaceAccountID"]) ?? [:]
    let storeURL = applicationSupport.appending(path: "managed-codex-accounts.json")
    let store = try? localJSONObject(at: storeURL, maximumBytes: 2_097_152)
    let rawAccounts = store?["accounts"] as? [[String: Any]] ?? []
    return rawAccounts.compactMap { raw in
      guard let homePath = string(raw["managedHomePath"]),
            let email = string(raw["email"]),
            let workspaceID = string(raw["workspaceAccountID"] ?? raw["providerAccountID"]),
            !workspaceID.isEmpty
      else { return nil }
      let homeURL = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
      guard homeURL.path.hasPrefix(managedHomes.path + "/") else { return nil }
      let credentialsURL = homeURL.appending(path: "auth.json")
      guard FileManager.default.fileExists(atPath: credentialsURL.path) else { return nil }
      let name = string(raw["workspaceLabel"])
        ?? string(labels[workspaceID])
        ?? "OpenAI workspace"
      return CodexWorkspaceSource(
        workspace: CodexUsageWorkspace(id: workspaceID, name: name, email: email),
        credentialsURL: credentialsURL,
        isLive: false
      )
    }
  }

  static func resolveCodexWorkspaceSource(
    _ sources: [CodexWorkspaceSource],
    selectedID: String?
  ) -> CodexWorkspaceSource? {
    if let selectedID,
       let selected = sources.first(where: { $0.workspace.id == selectedID }) {
      return selected
    }
    return sources.first(where: \.isLive) ?? sources.first
  }

  static func codexEnvironmentOverrides(
    for source: CodexWorkspaceSource?
  ) -> [String: String] {
    source.map {
      ["CODEX_HOME": $0.credentialsURL.deletingLastPathComponent().path]
    } ?? [:]
  }

  private static func codexIdentityEmail(root: [String: Any]) -> String? {
    guard let tokens = dictionary(root["tokens"]),
          let idToken = string(tokens["id_token"] ?? tokens["idToken"]),
          let payload = decodeJWTPayload(idToken)
    else { return nil }
    return string(payload["email"])
  }

  private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let components = token.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count > 1 else { return nil }
    var value = String(components[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value),
          data.count <= 1_048_576,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
  }

  private static func codex(
    homeDirectory: URL,
    workspaceSource: CodexWorkspaceSource?,
    workspaceCount: Int,
    now: Date
  ) async -> UsageLimitAccount {
    if let workspaceSource {
      if let direct = try? await codexOAuth(
        credentialsURL: workspaceSource.credentialsURL,
        workspace: workspaceSource.workspace,
        showsWorkspaceIdentity: workspaceCount > 1,
        now: now
      ) {
        return direct
      }
    } else if let direct = try? await codexOAuth(homeDirectory: homeDirectory, now: now) {
      return direct
    }
    guard let executable = LocalACPRuntimeResolver.resolveExecutable(named: "codex") else {
      if let workspaceSource {
        return unavailable(
          .codex,
          accountScopeID: workspaceSource.workspace.id,
          accountLabel: workspaceSource.workspace.selectionLabel,
          detail: "Codex CLI is not installed, so this saved OpenAI workspace cannot refresh.",
          now: now
        )
      }
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
        environmentOverrides: codexEnvironmentOverrides(for: workspaceSource),
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
      let result = UsageLimitAccount(
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
      if let workspaceSource {
        return scopedCodexAccount(
          result,
          workspace: workspaceSource.workspace,
          showsWorkspaceIdentity: workspaceCount > 1
        )
      }
      return result
    } catch {
      if let workspaceSource {
        return failed(
          .codex,
          accountScopeID: workspaceSource.workspace.id,
          accountLabel: workspaceSource.workspace.selectionLabel,
          detail: "This saved OpenAI workspace could not refresh from its isolated Codex home.",
          now: now
        )
      }
      let result = codexLocalSignIn(now: now) ?? failed(
        .codex,
        detail: "Codex account limits could not be read from the local CLI.",
        now: now
      )
      return result
    }
  }

  private static func claude(
    homeDirectory: URL,
    keychainInteraction: UsageKeychainInteraction,
    now: Date
  ) async -> UsageLimitAccount {
    if let direct = try? await claudeOAuth(
      homeDirectory: homeDirectory,
      keychainInteraction: keychainInteraction,
      now: now
    ) {
      return direct
    }
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
          ? "Signed in via \(method ?? "Claude CLI"). The OAuth usage endpoint was unavailable, so no limits are inferred."
          : "Claude CLI is installed but not signed in.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.claude
      )
    } catch {
      return failed(.claude, detail: "Claude sign-in state could not be read from the local CLI.", now: now)
    }
  }

  private static func grok(homeDirectory: URL, now: Date) async -> UsageLimitAccount {
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
      let tier = string(billing["subscriptionTier"] ?? billing["subscription_tier"])
      let email = string(billing["email"] ?? dictionary(billing["account"])?["email"])
      return UsageLimitAccount(
        provider: .grok,
        accountLabel: email ?? tier ?? "Grok account",
        status: windows.isEmpty ? .signedIn : .available,
        quotaWindows: windows,
        providerBudget: providerBudget,
        details: tier.map { [.init(label: "Plan", value: $0)] } ?? [],
        source: "Grok CLI billing RPC",
        detail: windows.isEmpty
          ? "Grok is reachable, but the signed-in account returned no numeric billing limit."
          : "Live billing-cycle credits returned by the locally signed-in Grok CLI.",
        observedAt: now,
        dashboardURL: ProviderDashboardURL.grok
      )
    } catch {
      if let proxy = try? await grokProxy(homeDirectory: homeDirectory, now: now) {
        return proxy
      }
      return grokLocalSignIn(now: now) ?? failed(
        .grok,
        detail: "Grok account billing was unavailable. Sign in with the Grok CLI to enable it.",
        now: now
      )
    }
  }

  private static func codexOAuth(
    homeDirectory: URL,
    now: Date
  ) async throws -> UsageLimitAccount {
    let configured = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    return try await codexOAuth(
      credentialsURL: (configured ?? homeDirectory.appending(path: ".codex"))
        .appending(path: "auth.json"),
      workspace: nil,
      showsWorkspaceIdentity: false,
      now: now
    )
  }

  private static func codexOAuth(
    credentialsURL: URL,
    workspace: CodexUsageWorkspace?,
    showsWorkspaceIdentity: Bool,
    now: Date
  ) async throws -> UsageLimitAccount {
    let root = try localJSONObject(at: credentialsURL, maximumBytes: 1_048_576)
    let tokens = dictionary(root["tokens"])
    guard let token = string(tokens?["access_token"] ?? tokens?["accessToken"]) else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    var headers: [String: String] = [:]
    if let accountID = string(
      tokens?["account_id"] ?? tokens?["accountId"]
        ?? root["account_id"] ?? root["accountId"]
    ) {
      headers["ChatGPT-Account-Id"] = accountID
    }
    async let usageObject = authenticatedJSONObject(
      url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
      bearer: token,
      headers: headers
    )
    async let resetObject = try? authenticatedJSONObject(
      url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
      bearer: token,
      headers: headers.merging([
        "OpenAI-Beta": "codex-1",
        "originator": "Codex Desktop",
      ], uniquingKeysWith: { current, _ in current })
    )
    var account = mapCodexUsage(try await usageObject, now: now)
    if let workspace {
      account = scopedCodexAccount(
        account,
        workspace: workspace,
        showsWorkspaceIdentity: showsWorkspaceIdentity
      )
    }
    guard let reset = await resetObject else { return account }
    var details = account.details
    if let credits = number(reset["credits"] ?? reset["balance"]
      ?? reset["reset_credits"] ?? reset["resetCredits"]) {
      details.append(.init(label: "Reset credits", value: credits.formatted()))
    }
    return UsageLimitAccount(
      provider: account.provider,
      accountScopeID: account.accountScopeID,
      accountLabel: account.accountLabel,
      status: account.status,
      quotaWindows: account.quotaWindows,
      balance: account.balance,
      providerBudget: account.providerBudget,
      details: details,
      history: account.history,
      source: account.source,
      detail: account.detail,
      observedAt: account.observedAt,
      dashboardURL: account.dashboardURL
    )
  }

  static func scopedCodexAccount(
    _ account: UsageLimitAccount,
    workspace: CodexUsageWorkspace,
    showsWorkspaceIdentity: Bool
  ) -> UsageLimitAccount {
    var details = account.details
    if showsWorkspaceIdentity {
      details.insert(.init(label: "Workspace", value: workspace.name), at: 0)
    }
    return UsageLimitAccount(
      provider: account.provider,
      accountScopeID: workspace.id,
      accountLabel: showsWorkspaceIdentity ? workspace.selectionLabel : account.accountLabel,
      status: account.status,
      quotaWindows: account.quotaWindows,
      balance: account.balance,
      providerBudget: account.providerBudget,
      details: details,
      history: account.history,
      source: account.source,
      detail: account.detail,
      observedAt: account.observedAt,
      isStale: account.isStale,
      refreshError: account.refreshError,
      dashboardURL: account.dashboardURL
    )
  }

  static func mapCodexUsage(
    _ object: [String: Any],
    now: Date
  ) -> UsageLimitAccount {
    let rateLimit = dictionary(object["rate_limit"] ?? object["rateLimit"])
    var windows: [ProviderQuotaWindow] = []
    if let window = quotaWindow(
      rateLimit?["primary_window"] ?? rateLimit?["primaryWindow"],
      id: "five-hour",
      label: "Five-hour"
    ) { windows.append(window) }
    if let window = quotaWindow(
      rateLimit?["secondary_window"] ?? rateLimit?["secondaryWindow"],
      id: "weekly",
      label: "Weekly"
    ) { windows.append(window) }
    if let extra = object["additional_rate_limits"] as? [[String: Any]] {
      for (index, item) in extra.enumerated() {
        let nested = dictionary(item["rate_limit"] ?? item["rateLimit"])
        let label = string(item["limit_name"] ?? item["limitName"]
          ?? item["metered_feature"] ?? item["meteredFeature"])
          ?? "Additional limit \(index + 1)"
        if let window = quotaWindow(
          nested?["primary_window"] ?? nested?["primaryWindow"],
          id: "additional-\(index)-primary",
          label: label
        ) { windows.append(window) }
        if let window = quotaWindow(
          nested?["secondary_window"] ?? nested?["secondaryWindow"],
          id: "additional-\(index)-secondary",
          label: "\(label) weekly"
        ) { windows.append(window) }
      }
    }
    let credits = dictionary(object["credits"])
    let balance = number(credits?["balance"] ?? credits?["remaining"])
    let individual = dictionary(
      object["individual_limit"] ?? object["individualLimit"]
        ?? rateLimit?["individual_limit"] ?? rateLimit?["individualLimit"]
        ?? dictionary(object["spend_control"] ?? object["spendControl"])?["individual_limit"]
    )
    let used = number(individual?["used"] ?? individual?["usage"]
      ?? individual?["used_amount"] ?? individual?["usedAmount"])
    let limit = number(individual?["limit"] ?? individual?["amount"]
      ?? individual?["limit_amount"] ?? individual?["limitAmount"])
    let budget = used.flatMap { used in limit.flatMap { limit in
      limit > 0 ? ProviderReportedBudget(
        usedMicros: micros(used), limitMicros: micros(limit), currency: "USD",
        period: "monthly", resetsAt: nil, scope: "account"
      ) : nil
    }}
    let plan = string(object["plan_type"] ?? object["planType"])
    var details: [ProviderUsageDetail] = []
    if let plan { details.append(.init(label: "Plan", value: plan.replacingOccurrences(of: "_", with: " ").capitalized)) }
    if boolean(credits?["unlimited"]) == true {
      details.append(.init(label: "Credits", value: "Unlimited"))
    }
    return UsageLimitAccount(
      provider: .codex,
      accountLabel: plan.map { "Codex \($0.replacingOccurrences(of: "_", with: " ").capitalized)" }
        ?? "Codex account",
      status: windows.isEmpty && budget == nil && balance == nil ? .signedIn : .available,
      quotaWindows: windows,
      balance: balance.map { ProviderMoney(amountMicros: micros($0), currency: "USD") },
      providerBudget: budget,
      details: details,
      source: "OpenAI subscription usage API",
      detail: "Live Codex subscription windows and credit controls from the signed-in OpenAI account.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.codex
    )
  }

  private static func claudeOAuth(
    homeDirectory: URL,
    keychainInteraction: UsageKeychainInteraction,
    now: Date
  ) async throws -> UsageLimitAccount {
    let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let credentialURL = (configured ?? homeDirectory.appending(path: ".claude"))
      .appending(path: ".credentials.json")
    guard let token = claudeOAuthToken(
      credentialsURL: credentialURL,
      keychainInteraction: keychainInteraction
    ) else {
      throw ProviderLimitCollectorError.invalidResponse
    }
    let object = try await authenticatedJSONObject(
      url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
      bearer: token,
      headers: [
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
        "User-Agent": "claude-code/2.1.0",
      ]
    )
    return mapClaudeUsage(object, now: now)
  }

  private static func claudeOAuthToken(
    credentialsURL: URL,
    keychainInteraction: UsageKeychainInteraction
  ) -> String? {
    if let root = try? localJSONObject(at: credentialsURL, maximumBytes: 1_048_576),
       let oauth = dictionary(root["claudeAiOauth"]),
       let token = string(oauth["accessToken"] ?? oauth["access_token"]) {
      return token
    }
    let context = claudeAuthenticationContext(for: keychainInteraction)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          data.count <= 1_048_576,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = dictionary(root["claudeAiOauth"])
    else { return nil }
    return string(oauth["accessToken"] ?? oauth["access_token"])
  }

  static func claudeAuthenticationContext(
    for interaction: UsageKeychainInteraction
  ) -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = !interaction.allowsInteraction
    return context
  }

  static func mapClaudeUsage(
    _ object: [String: Any],
    now: Date
  ) -> UsageLimitAccount {
    let mappings: [(String, String, String)] = [
      ("five_hour", "five-hour", "Five-hour"),
      ("seven_day", "weekly", "Weekly"),
      ("seven_day_sonnet", "sonnet-weekly", "Sonnet weekly"),
      ("seven_day_opus", "opus-weekly", "Opus weekly"),
      ("seven_day_oauth_apps", "oauth-apps-weekly", "OAuth apps weekly"),
      ("seven_day_routines", "routines-weekly", "Routines weekly"),
      ("seven_day_claude_routines", "routines-weekly", "Routines weekly"),
      ("claude_routines", "routines-weekly", "Routines weekly"),
      ("routines", "routines-weekly", "Routines weekly"),
      ("routine", "routines-weekly", "Routines weekly"),
      ("seven_day_cowork", "routines-weekly", "Routines weekly"),
      ("cowork", "routines-weekly", "Routines weekly"),
      ("iguana_necktie", "iguana-necktie", "Promotional weekly"),
    ]
    var seen = Set<String>()
    var windows = mappings.compactMap { key, id, label -> ProviderQuotaWindow? in
      guard let raw = dictionary(object[key]), seen.insert(id).inserted,
            let utilization = number(raw["utilization"]), utilization >= 0 else { return nil }
      return ProviderQuotaWindow(
        id: id, label: label, usedPercent: utilization, usageKnown: true,
        windowMinutes: nil, resetsAt: parseDate(string(raw["resets_at"])),
        resetDescription: nil
      )
    }
    if let scoped = object["limits"] as? [[String: Any]] {
      for (index, limit) in scoped.enumerated() where boolean(limit["is_active"]) != false {
        guard let percent = number(limit["percent"] ?? limit["utilization"]) else { continue }
        let model = string(dictionary(dictionary(limit["scope"])?["model"])?["display_name"])
        let label = model.map { "\($0) weekly" } ?? "Scoped weekly"
        windows.append(ProviderQuotaWindow(
          id: "scoped-weekly-\(index)", label: label, usedPercent: percent,
          usageKnown: true, windowMinutes: nil,
          resetsAt: parseDate(string(limit["resets_at"])), resetDescription: nil
        ))
      }
    }
    let extra = dictionary(object["extra_usage"])
    let extraEnabled = boolean(extra?["is_enabled"]) == true
    let used = extraEnabled ? number(extra?["used_credits"]) : nil
    let limit = extraEnabled ? number(extra?["monthly_limit"]) : nil
    let currency = string(extra?["currency"]) ?? "USD"
    let budget = used.flatMap { used in limit.flatMap { limit in
      limit > 0 ? ProviderReportedBudget(
        usedMicros: micros(used / 100), limitMicros: micros(limit / 100),
        currency: currency, period: "monthly", resetsAt: nil, scope: "extra usage"
      ) : nil
    }}
    return UsageLimitAccount(
      provider: .claude,
      accountLabel: "Claude account",
      status: windows.isEmpty && budget == nil ? .signedIn : .available,
      quotaWindows: windows,
      providerBudget: budget,
      source: "Anthropic OAuth usage API",
      detail: "Live Claude session, weekly, model, routine, scoped, and extra-usage limits.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.claude
    )
  }

  private static func grokProxy(
    homeDirectory: URL,
    now: Date
  ) async throws -> UsageLimitAccount {
    let configured = ProcessInfo.processInfo.environment["GROK_HOME"].map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let root = try localJSONObject(
      at: (configured ?? homeDirectory.appending(path: ".grok"))
        .appending(path: "auth.json"),
      maximumBytes: 1_048_576
    )
    guard let entry = root.values.compactMap(dictionary).first(where: {
      string($0["key"] ?? $0["access_token"] ?? $0["accessToken"]) != nil
    }), let token = string(entry["key"] ?? entry["access_token"] ?? entry["accessToken"])
    else { throw ProviderLimitCollectorError.invalidResponse }
    let object = try await authenticatedJSONObject(
      url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
      bearer: token,
      headers: ["x-xai-token-auth": "xai-grok-cli"]
    )
    return mapGrokProxy(object, accountLabel: string(entry["email"]), now: now)
  }

  static func mapGrokProxy(
    _ object: [String: Any],
    accountLabel: String?,
    now: Date
  ) -> UsageLimitAccount {
    let config = dictionary(object["config"]) ?? object
    let used = number(dictionary(config["onDemandUsed"] ?? config["on_demand_used"])?["val"]
      ?? config["onDemandUsed"] ?? config["on_demand_used"])
    let cap = number(dictionary(config["onDemandCap"] ?? config["on_demand_cap"])?["val"]
      ?? config["onDemandCap"] ?? config["on_demand_cap"])
    let directPercent = number(config["creditUsagePercent"] ?? config["credit_usage_percent"])
    let percent = directPercent ?? used.flatMap { used in cap.flatMap { $0 > 0 ? used / $0 * 100 : nil } }
    let currentPeriod = dictionary(config["currentPeriod"] ?? config["current_period"])
    let reset = parseDate(string(currentPeriod?["end"]
      ?? config["billingPeriodEnd"] ?? config["billing_period_end"]
      ?? config["resetAt"] ?? config["reset_at"]))
    let windows = percent.map { [ProviderQuotaWindow(
      id: "billing-cycle", label: "Monthly credits", usedPercent: $0,
      usageKnown: true, windowMinutes: nil, resetsAt: reset
    )] } ?? []
    let tier = string(config["subscriptionTier"] ?? config["subscription_tier"])
    return UsageLimitAccount(
      provider: .grok,
      accountLabel: accountLabel ?? tier ?? "Grok account",
      status: windows.isEmpty ? .signedIn : .available,
      quotaWindows: windows,
      details: tier.map { [.init(label: "Plan", value: $0)] } ?? [],
      source: "Grok CLI proxy billing API",
      detail: "Live Grok credit allowance from the signed-in CLI proxy.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.grok
    )
  }

  static func openCodeGo(apiKey: String, now: Date) async throws -> UsageLimitAccount {
    let object = try await authenticatedJSONObject(
      url: URL(string: "https://opencode.ai/zen/go/v1/usage")!,
      bearer: apiKey,
      headers: ["User-Agent": "WovenMatter"]
    )
    return mapOpenCodeGoUsage(object, now: now)
  }

  static func mapOpenCodeGoUsage(
    _ object: [String: Any],
    now: Date
  ) -> UsageLimitAccount {
    let usage = dictionary(object["usage"]) ?? object
    let mappings: [(String, String, String, Int?)] = [
      ("rolling", "rolling-five-hour", "Rolling five-hour", 5 * 60),
      ("weekly", "weekly", "Weekly", 7 * 24 * 60),
      ("monthly", "monthly", "Monthly", 30 * 24 * 60),
    ]
    let windows = mappings.compactMap { key, id, label, minutes -> ProviderQuotaWindow? in
      guard let raw = dictionary(usage[key]),
            let percent = number(raw["usagePercent"] ?? raw["usedPercent"]
              ?? raw["usage_percent"] ?? raw["used_percent"] ?? raw["percent"])
      else { return nil }
      let resetSeconds = integer(raw["resetInSec"] ?? raw["reset_in_sec"]
        ?? raw["resetSeconds"])
      let reset = parseDate(string(raw["resetAt"] ?? raw["reset_at"]
        ?? raw["renewsAt"] ?? raw["renews_at"]))
        ?? resetSeconds.map { now.addingTimeInterval(TimeInterval(max(0, $0))) }
      return ProviderQuotaWindow(
        id: id, label: label, usedPercent: percent, usageKnown: true,
        windowMinutes: minutes, resetsAt: reset
      )
    }
    let balance = number(object["balance"] ?? object["balanceUSD"]
      ?? usage["balance"] ?? usage["balanceUSD"])
    return UsageLimitAccount(
      provider: .openCodeGo,
      accountLabel: "OpenCode Go",
      status: windows.isEmpty && balance == nil ? .signedIn : .available,
      quotaWindows: windows,
      balance: balance.map { ProviderMoney(amountMicros: micros($0), currency: "USD") },
      source: "OpenCode Go usage API",
      detail: "Authoritative rolling, weekly, and monthly subscription windows; local database history is shown separately.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.openCodeGo
    )
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
      return mapOpenRouter(keyObject: keyObject, creditsObject: creditsObject, now: now)
    } catch {
      return failed(.openRouter, detail: "OpenRouter rejected the stored key or did not return credit data.", now: now)
    }
  }

  static func mapOpenRouter(
    keyObject: [String: Any]?,
    creditsObject: [String: Any]?,
    now: Date
  ) -> UsageLimitAccount {
    let key = dictionary(keyObject?["data"]) ?? keyObject
    let credits = dictionary(creditsObject?["data"]) ?? creditsObject
    let keyLimit = number(key?["limit"])
    let keyUsage = number(key?["usage"])
    let serverRemaining = number(key?["limit_remaining"] ?? key?["limitRemaining"])
    let reset = string(key?["limit_reset"] ?? key?["limitReset"])
    let matchingUsage: Double? = switch reset?.lowercased() {
    case "daily": number(key?["usage_daily"] ?? key?["usageDaily"])
    case "weekly": number(key?["usage_weekly"] ?? key?["usageWeekly"])
    case "monthly": number(key?["usage_monthly"] ?? key?["usageMonthly"])
    default: nil
    }
    let resolvedKeyUsed = keyLimit.flatMap { limit -> Double? in
      if let serverRemaining { return max(0, limit - min(limit, max(0, serverRemaining))) }
      return matchingUsage ?? keyUsage
    }
    let keyBudget = keyLimit.flatMap { limit in resolvedKeyUsed.flatMap { used in
      limit > 0 ? ProviderReportedBudget(
        usedMicros: micros(used), limitMicros: micros(limit), currency: "USD",
        period: reset, resetsAt: nil, scope: "api-key"
      ) : nil
    }}
    let totalCredits = number(credits?["total_credits"] ?? credits?["totalCredits"])
    let totalUsage = number(credits?["total_usage"] ?? credits?["totalUsage"])
    let accountBalance = totalCredits.flatMap { total in totalUsage.map { max(0, total - $0) } }
    var details: [ProviderUsageDetail] = []
    func add(_ label: String, _ value: Double?) {
      guard let value else { return }
      details.append(.init(label: label, value: value.formatted(.currency(code: "USD"))))
    }
    add("Credits remaining", accountBalance)
    add("Credits used", totalUsage)
    add("Credits total", totalCredits)
    add("Key cap", keyLimit)
    add("Key remaining", serverRemaining ?? keyBudget.map { Double($0.remainingMicros) / 1_000_000 })
    add("Today", number(key?["usage_daily"] ?? key?["usageDaily"]))
    add("This week", number(key?["usage_weekly"] ?? key?["usageWeekly"]))
    add("This month", number(key?["usage_monthly"] ?? key?["usageMonthly"]))
    if let rate = dictionary(key?["rate_limit"] ?? key?["rateLimit"]),
       let requests = integer(rate["requests"]), requests >= 0,
       let interval = string(rate["interval"]) {
      details.append(.init(label: "Rate limit", value: "\(requests) requests / \(interval)"))
    }
    let windows = keyBudget.map { budget in [ProviderQuotaWindow(
      id: "api-key-cap", label: "API key cap", usedPercent: budget.usedPercent,
      usageKnown: true, windowMinutes: nil, resetsAt: nil,
      resetDescription: reset.map { "Resets \($0)" }
    )] } ?? []
    return UsageLimitAccount(
      provider: .openRouter,
      accountLabel: safeOpenRouterLabel(key?["label"] ?? key?["name"]),
      status: keyObject == nil && creditsObject == nil ? .failed : .available,
      quotaWindows: windows,
      balance: accountBalance.map { ProviderMoney(amountMicros: micros($0), currency: "USD") },
      providerBudget: keyBudget,
      details: details,
      source: "OpenRouter credits and key APIs",
      detail: "Account credits and the API key cap are independent. Values shown here come only from the stored API key.",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.openRouter
    )
  }

  private static func safeOpenRouterLabel(_ value: Any?) -> String {
    guard let label = string(value),
          !label.lowercased().hasPrefix("sk-") else { return "OpenRouter API key" }
    return label
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

  private static func authenticatedJSONObject(
    url: URL,
    bearer: String,
    headers: [String: String] = [:]
  ) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await BoundedHTTPResponse.data(
      for: request,
      using: .shared,
      maximumBytes: 1_048_576
    )
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ProviderLimitCollectorError.invalidResponse }
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
    accountScopeID: String? = nil,
    accountLabel: String? = nil,
    detail: String,
    now: Date
  ) -> UsageLimitAccount {
    UsageLimitAccount(
      provider: provider,
      accountScopeID: accountScopeID,
      accountLabel: accountLabel ?? provider.displayName,
      status: .unavailable,
      source: "Local CLI",
      detail: detail,
      observedAt: now
    )
  }

  private static func failed(
    _ provider: ProviderKind,
    accountScopeID: String? = nil,
    accountLabel: String? = nil,
    detail: String,
    now: Date
  ) -> UsageLimitAccount {
    UsageLimitAccount(
      provider: provider,
      accountScopeID: accountScopeID,
      accountLabel: accountLabel ?? provider.displayName,
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
  fileprivate static func micros(_ dollars: Double) -> Int64 {
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
    environmentOverrides: [String: String] = [:],
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
            environmentOverrides: environmentOverrides,
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
    environmentOverrides: [String: String],
    maximumBytes: Int
  ) throws -> Data {
    let process = command.process
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.executableURL = executable
    process.arguments = arguments
    process.environment = usageCommandEnvironment().merging(
      environmentOverrides,
      uniquingKeysWith: { _, override in override }
    )
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

  func account(now: Date) async -> UsageLimitAccount {
    let root = homeDirectory.appending(path: ".local/share/opencode", directoryHint: .isDirectory)
    let authURL = root.appending(path: "auth.json")
    let databaseURL = root.appending(path: "opencode.db")
    let apiKey = authKey(at: authURL)
    let authenticated = apiKey != nil
    let rows = (try? readRows(databaseURL)) ?? []
    let history = dailyHistory(rows)
    if let apiKey, let live = try? await ProviderLimitCollector.openCodeGo(
      apiKey: apiKey,
      now: now
    ) {
      return UsageLimitAccount(
        provider: live.provider,
        accountLabel: live.accountLabel,
        status: live.status,
        quotaWindows: live.quotaWindows,
        balance: live.balance,
        providerBudget: live.providerBudget,
        details: live.details,
        history: history,
        source: live.source,
        detail: live.detail,
        observedAt: live.observedAt,
        dashboardURL: live.dashboardURL
      )
    }
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
    guard authenticated || !rows.isEmpty else {
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
      history: history,
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

  private func authKey(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entry = object["opencode-go"] as? [String: Any]
    else { return nil }
    let value = (entry["key"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  private func dailyHistory(_ rows: [Row]) -> [ProviderUsageHistoryPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return Dictionary(grouping: rows, by: { calendar.startOfDay(for: $0.createdAt) })
      .map { day, values in
        ProviderUsageHistoryPoint(
          date: day,
          valueMicros: ProviderLimitCollector.micros(
            values.reduce(0) { $0 + $1.cost }
          )
        )
      }
      .sorted { $0.date < $1.date }
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
