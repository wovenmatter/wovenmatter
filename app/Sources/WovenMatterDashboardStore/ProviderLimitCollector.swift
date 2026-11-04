import Foundation
import WovenMatterClient
import WovenMatterCore

struct CodexWorkspaceSource: Sendable {
  let workspace: CodexUsageWorkspace
  let credentialsURL: URL
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
    enabledProviders: Set<ProviderKind>,
    sharedCredentials: [String: DefaultAgentCredential],
    selectedConnections: [ProviderKind: UsageConnectionChoice] = [:],
    claudeStatus: BuiltInClaudeSignIn.Status? = nil,
    now: Date
  ) async -> [UsageLimitAccount] {
    let enabled = await withTaskGroup(
      of: UsageLimitAccount.self,
      returning: [UsageLimitAccount].self
    ) { group in
      for provider in ProviderKind.supportedAccounts
        where enabledProviders.contains(provider) {
        group.addTask {
          let choice = selectedConnections[provider]
          if let choice, ["openai", "anthropic", "xai-api"].contains(choice.connectionID) {
            return apiKeyAccount(provider, choice: choice, present: sharedCredentials[choice.connectionID]?.key != nil, now: now)
          }
          if provider == .claude {
            return UsageLimitAccount(provider: .claude, accountScopeID: choice.map { "wovenmatter.shared." + $0.id }, accountLabel: claudeStatus?.account ?? choice?.label ?? "Claude subscription",
              status: claudeStatus?.connected == true ? .signedIn
                : (claudeStatus?.state == "sign_in_required" || choice == nil && sharedCredentials["claude-subscription"] == nil ? .needsCredential : .unavailable),
              source: "Pi Durable · Claude SDK", detail: claudeStatus?.connected == true
                ? "Claude manages this sign-in. Check subscription limits and extra usage in your Claude account. API keys are billed separately."
                : "Manage Claude subscription sign-in and API keys in Settings → Usage.", observedAt: now,
              dashboardURL: ProviderDashboardURL.claude)
          }
          return await sharedAccount(provider, credentials: sharedCredentials, now: now, choice: choice)
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
        credentialsURL: credentialsURL
      )
    }
  }

  static func apiKeyAccount(_ provider: ProviderKind, choice: UsageConnectionChoice, present: Bool, now: Date) -> UsageLimitAccount {
    UsageLimitAccount(provider: provider, accountScopeID: "wovenmatter.shared.\(choice.id)",
      accountLabel: choice.label, status: present ? .signedIn : .unavailable,
      source: "Saved accounts",
      detail: present
        ? "API key saved. This connection does not expose subscription usage limits here. Check API billing and limits in the provider dashboard."
        : "This saved key could not be read. Check Keychain access or update it in Settings → Usage.",
      observedAt: now, dashboardURL: provider == .codex ? URL(string: "https://platform.openai.com/usage")
        : provider == .claude ? URL(string: "https://platform.claude.com/settings/usage")
        : URL(string: "https://console.x.ai/"))
  }

  private static func sharedAccount(_ provider: ProviderKind, credentials: [String: DefaultAgentCredential], now: Date, mayRenew: Bool = true, choice: UsageConnectionChoice? = nil) async -> UsageLimitAccount {
    let id: String
    switch provider {
    case .codex: id = "openai-codex"
    case .grok: id = "xai"
    case .openCodeGo: id = "opencode-go"
    case .openRouter: id = "openrouter"
    default: return unavailable(provider, detail: "This provider has no shared connection.", now: now)
    }
    guard let credential = credentials[id], let token = credential.access ?? credential.key else {
      return UsageLimitAccount(provider: provider, accountScopeID: choice.map { "wovenmatter.shared." + $0.id },
        accountLabel: choice?.label ?? provider.displayName, status: choice == nil ? .needsCredential : .unavailable,
        source: "Saved accounts", detail: choice == nil ? "Not signed in. Add an account in Settings → Usage."
          : "This saved account could not be read. Check Keychain access in Settings → General.", observedAt: now)
    }
    do {
      let account: UsageLimitAccount
      switch provider {
      case .codex:
        var headers: [String: String] = [:]
        if let id = credential.accountId { headers["ChatGPT-Account-Id"] = id }
        let object = try await authenticatedJSONObject(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, bearer: token, headers: headers)
        account = mapCodexUsage(object, now: now)
      case .grok:
        let object = try await authenticatedJSONObject(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, bearer: token,
          headers: ["x-xai-token-auth": "xai-grok-cli"])
        account = mapGrokProxy(object, accountLabel: credential.accountLabel, now: now)
      case .openCodeGo: account = try await openCodeGo(apiKey: token, now: now)
      case .openRouter: account = await openRouter(apiKey: token, now: now)
      default: return unavailable(provider, detail: "Usage is unavailable.", now: now)
      }
      return UsageLimitAccount(provider: account.provider, accountScopeID: "wovenmatter.shared.\(choice?.id ?? id)",
        accountLabel: choice?.label ?? credential.accountLabel ?? account.accountLabel, status: account.status,
        quotaWindows: account.quotaWindows, balance: account.balance, providerBudget: account.providerBudget,
        details: account.details, history: account.history, source: "Woven Matter shared connection · \(account.source)",
        detail: account.detail, observedAt: account.observedAt, dashboardURL: account.dashboardURL)
    } catch {
      let rejected = (error as? SharedAccountHTTPError)?.status == 401
      if rejected, mayRenew, choice == nil || choice?.preferred == true, credential.type == "oauth",
         let renewed = try? await ProviderAccountCoordinator.shared.renewRejectedAccess(provider: id, access: token) {
        var updated = credentials; updated[id] = renewed
        return await sharedAccount(provider, credentials: updated, now: now, mayRenew: false, choice: choice)
      }
      return UsageLimitAccount(provider: provider, accountScopeID: "wovenmatter.shared.\(choice?.id ?? id)",
        accountLabel: choice?.label ?? credential.accountLabel ?? provider.displayName, status: rejected ? .needsCredential : .unavailable,
        source: "Saved accounts", detail: rejected ? "Reconnect this account in Settings → Usage." : "Usage could not be checked. Manage or refresh this account in Settings → Usage.", observedAt: now)
    }
  }

  static func mapCodexUsage(
    _ object: [String: Any],
    now: Date
  ) -> UsageLimitAccount {
    let rateLimit = dictionary(object["rate_limit"] ?? object["rateLimit"])
    var windows: [ProviderQuotaWindow] = []
    if let window = codexPrimaryWindow(
      rateLimit?["primary_window"] ?? rateLimit?["primaryWindow"]
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

  private struct SharedAccountHTTPError: Error { let status: Int }

  private static func authenticatedJSONObject(
    url: URL,
    bearer: String,
    headers: [String: String] = [:],
    onResponse: (@Sendable (Int) -> Void)? = nil
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
    if let http = response as? HTTPURLResponse { onResponse?(http.statusCode) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw SharedAccountHTTPError(status: http.statusCode)
    }
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
    let minutes = quotaWindowDurationMinutes(value)
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

  private static func codexPrimaryWindow(_ raw: Any?) -> ProviderQuotaWindow? {
    guard let value = dictionary(raw) else { return nil }
    let label = quotaWindowDurationMinutes(value) == 7 * 24 * 60
      ? "Weekly"
      : "Five-hour"
    return quotaWindow(value, id: "five-hour", label: label)
  }

  private static func quotaWindowDurationMinutes(_ value: [String: Any]) -> Int? {
    integer(value["windowDurationMins"] ?? value["window_duration_mins"])
      .flatMap(Int.init(exactly:))
      ?? integer(value["limitWindowSeconds"] ?? value["limit_window_seconds"])
        .flatMap(Int.init(exactly:))
        .map { $0 / 60 }
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
  static let openCodeGo = URL(string: "https://opencode.ai/auth")
  static let openRouter = URL(string: "https://openrouter.ai/settings/credits")
}

private enum ProviderLimitCollectorError: Error {
  case invalidResponse
}
