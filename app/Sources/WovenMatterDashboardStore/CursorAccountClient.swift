import Foundation
import SQLite3
import WovenMatterCore

struct CursorAccountActivity: Sendable {
  let accountLabel: String
  let samples: [UsageSample]
}

enum CursorAccountClientError: LocalizedError {
  case notSignedIn
  case invalidToken
  case rejected
  case invalidResponse
  case incompletePagination

  var errorDescription: String? {
    switch self {
    case .notSignedIn: "Cursor.app is not signed in."
    case .invalidToken: "Cursor.app's local account token is invalid or expired."
    case .rejected: "Cursor rejected the locally signed-in account session."
    case .invalidResponse: "Cursor returned an invalid usage response."
    case .incompletePagination: "Cursor usage pagination did not complete safely."
    }
  }
}

/// Account-wide Cursor analytics, adapted from CodexBar's Cursor app-auth and
/// dashboard event fetchers. The access token is read from Cursor's own local
/// SQLite state and used in memory; Woven Matter never copies it to Keychain or
/// its usage database.
struct CursorAccountClient: Sendable {
  private let homeDirectory: URL
  private let urlSession: URLSession
  private let baseURL = URL(string: "https://cursor.com")!

  init(homeDirectory: URL, urlSession: URLSession = .shared) {
    self.homeDirectory = homeDirectory
    self.urlSession = urlSession
  }

  func activity(since: Date, until: Date) async throws -> CursorAccountActivity {
    let session = try localSession()
    async let user = fetchUser(cookie: session.cookie)
    let events = try await fetchEvents(
      cookie: session.cookie,
      since: since,
      until: until
    )
    let accountLabel = (try? await user.email) ?? session.email ?? "Cursor account"
    let ordered = events.sorted { lhs, rhs in
      let left = lhs.timestamp ?? .distantPast
      let right = rhs.timestamp ?? .distantPast
      if left != right { return left < right }
      return Self.eventIdentity(lhs) < Self.eventIdentity(rhs)
    }
    var occurrences: [String: Int] = [:]
    let samples = ordered.compactMap { event -> UsageSample? in
      guard let timestamp = event.timestamp,
            let usage = event.tokenUsage,
            usage.isPlausible,
            usage.totalTokens > 0 else { return nil }
      let model = event.model?.trimmingCharacters(in: .whitespacesAndNewlines)
      let baseIdentity = Self.eventIdentity(event)
      let occurrence = occurrences[baseIdentity, default: 0]
      occurrences[baseIdentity] = occurrence + 1
      let identity = "\(baseIdentity):\(occurrence)"
      return UsageSample(
        id: "cursor-account:\(identity)",
        provider: .cursor,
        timestamp: timestamp,
        sessionID: "cursor-account",
        accountLabel: accountLabel,
        model: model?.isEmpty == false ? model! : "Unknown model",
        billingProvider: "Cursor",
        billingRoute: "Cursor subscription",
        harness: event.isHeadless == true ? "Cursor Agent" : "Cursor",
        application: "Cursor Usage API",
        tokens: UsageTokenCounts(
          inputTokens: Int64(usage.inputTokens),
          cachedInputTokens: Int64(usage.cacheReadTokens),
          cacheCreationTokens: Int64(usage.cacheWriteTokens),
          outputTokens: Int64(usage.outputTokens),
          reportedTotalTokens: usage.totalTokens
        ),
        costUSD: usage.validTotalCents.map { $0 / 100 },
        attributionConfidence: model == nil ? .aggregate : .exact,
        granularity: .modelCall,
        sourceID: "cursor:account",
        sourceEventID: identity
      )
    }
    return CursorAccountActivity(accountLabel: accountLabel, samples: samples)
  }

  private static func eventIdentity(_ event: CursorUsageEvent) -> String {
    let usage = event.tokenUsage
    return [
      String(Int64((event.timestamp ?? .distantPast).timeIntervalSince1970 * 1_000)),
      event.model?.lowercased() ?? "unknown",
      String(usage?.inputTokens ?? 0),
      String(usage?.cacheReadTokens ?? 0),
      String(usage?.cacheWriteTokens ?? 0),
      String(usage?.outputTokens ?? 0),
      event.isHeadless == true ? "headless" : "editor",
      usage?.totalCents.map { String($0) } ?? "no-cost",
    ].joined(separator: ":")
  }

  func limits(now: Date) async throws -> UsageLimitAccount {
    let session = try localSession()
    async let user = fetchUser(cookie: session.cookie)
    async let summary = fetchSummary(cookie: session.cookie)
    let (account, usage) = try await (user, summary)
    let sand = try? await fetchSand(cookie: session.cookie)
    let plan = usage.individualUsage?.plan
    let overall = usage.individualUsage?.overall
    let pooled = usage.teamUsage?.pooled
    let used = plan?.used ?? overall?.used ?? pooled?.used
    let limit = plan?.limit ?? overall?.limit ?? pooled?.limit
    let resetsAt = Self.date(usage.billingCycleEnd)
    let percent: Double? = if let total = plan?.totalPercentUsed {
      min(100, max(0, total))
    } else if let used, let limit, limit > 0 {
      min(100, max(0, Double(used) / Double(limit) * 100))
    } else {
      nil
    }
    var windows: [ProviderQuotaWindow] = percent.map {
      ProviderQuotaWindow(
        id: "billing-cycle",
        label: "Total",
        usedPercent: $0,
        usageKnown: true,
        windowMinutes: Self.windowMinutes(
          start: Self.date(usage.billingCycleStart),
          end: resetsAt
        ),
        resetsAt: resetsAt
      )
    }.map { [$0] } ?? []
    if let cursor = plan?.autoPercentUsed {
      windows.append(ProviderQuotaWindow(
        id: "cursor", label: "Cursor", usedPercent: cursor,
        usageKnown: true, windowMinutes: Self.windowMinutes(
          start: Self.date(usage.billingCycleStart), end: resetsAt
        ), resetsAt: resetsAt
      ))
    }
    if let thirdParty = plan?.apiPercentUsed {
      windows.append(ProviderQuotaWindow(
        id: "third-party", label: "Third Party", usedPercent: thirdParty,
        usageKnown: true, windowMinutes: Self.windowMinutes(
          start: Self.date(usage.billingCycleStart), end: resetsAt
        ), resetsAt: resetsAt
      ))
    }
    if sand?.hasNonZeroIncludedLimit == true, let grok = sand?.usagePercent {
      windows.append(ProviderQuotaWindow(
        id: "grok-bot", label: "Grok Bot", usedPercent: grok,
        usageKnown: true, windowMinutes: Self.windowMinutes(
          start: Self.date(sand?.currentPeriodStart), end: Self.date(sand?.nextResetTimestampUtc)
        ), resetsAt: Self.date(sand?.nextResetTimestampUtc)
      ))
    }
    let onDemand = usage.individualUsage?.onDemand ?? usage.teamUsage?.onDemand
    let budget: ProviderReportedBudget? = if let used = onDemand?.used,
      let limit = onDemand?.limit, limit > 0 {
      ProviderReportedBudget(
        usedMicros: Self.amountMicros(cents: used),
        limitMicros: Self.amountMicros(cents: limit),
        currency: "USD",
        period: "monthly",
        resetsAt: resetsAt,
        scope: "on-demand"
      )
    } else {
      nil
    }
    let details: [ProviderUsageDetail] = onDemand?.used.map { used in
      let usedText = (Double(used) / 100).formatted(.currency(code: "USD"))
      let value = onDemand?.limit.map {
        "\(usedText) / \((Double($0) / 100).formatted(.currency(code: "USD")))"
      } ?? usedText
      return ProviderUsageDetail(label: "On-demand spend", value: value)
    }.map { [$0] } ?? []
    return UsageLimitAccount(
      provider: .cursor,
      accountLabel: account.email ?? session.email ?? "Cursor account",
      status: windows.isEmpty && budget == nil ? .signedIn : .available,
      quotaWindows: windows,
      providerBudget: budget,
      details: details,
      source: "Cursor account usage APIs",
      detail: "Live account-wide Cursor usage from the same dashboard endpoints used by CodexBar (all devices).",
      observedAt: now,
      dashboardURL: ProviderDashboardURL.cursor
    )
  }

  private struct LocalSession {
    let cookie: String
    let email: String?
  }

  private func localSession() throws -> LocalSession {
    let database = homeDirectory.appending(
      path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    )
    guard FileManager.default.fileExists(atPath: database.path) else {
      throw CursorAccountClientError.notSignedIn
    }
    guard let token = try Self.sqliteValue(
      database: database,
      key: "cursorAuth/accessToken"
    ), !token.isEmpty else {
      throw CursorAccountClientError.notSignedIn
    }
    let payload = try Self.jwtPayload(token)
    guard let subject = payload["sub"] as? String,
          let userID = subject.split(separator: "|").last.map(String.init),
          !userID.isEmpty,
          let expiration = (payload["exp"] as? NSNumber)?.doubleValue,
          expiration > Date().addingTimeInterval(60).timeIntervalSince1970 else {
      throw CursorAccountClientError.invalidToken
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
      throw CursorAccountClientError.invalidToken
    }
    return LocalSession(
      cookie: "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
      email: payload["email"] as? String
    )
  }

  private func fetchEvents(cookie: String, since: Date, until: Date) async throws
    -> [CursorUsageEvent] {
    let pageSize = 1_000
    var result: [CursorUsageEvent] = []
    var expected: Int?
    var completed = false
    for page in 1...200 {
      var request = URLRequest(
        url: baseURL.appending(path: "api/dashboard/get-filtered-usage-events")
      )
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "page": page,
        "pageSize": pageSize,
        "startDate": String(Int64(since.timeIntervalSince1970 * 1_000)),
        "endDate": String(Int64(until.timeIntervalSince1970 * 1_000)),
      ])
      let data = try await responseData(request)
      let response = try JSONDecoder().decode(CursorUsageEventsPage.self, from: data)
      if let count = response.totalUsageEventsCount {
        guard count >= 0 else { throw CursorAccountClientError.invalidResponse }
        if let expected, expected != count { throw CursorAccountClientError.invalidResponse }
        expected = count
      }
      if response.usageEventsDisplay.isEmpty {
        completed = true
        break
      }
      result += response.usageEventsDisplay
      if response.usageEventsDisplay.count < pageSize {
        completed = true
        break
      }
    }
    guard completed, expected.map({ result.count >= $0 }) ?? true else {
      throw CursorAccountClientError.incompletePagination
    }
    return expected.map { Array(result.prefix($0)) } ?? result
  }

  private func fetchSummary(cookie: String) async throws -> CursorUsageSummary {
    var request = URLRequest(url: baseURL.appending(path: "api/usage-summary"))
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return try JSONDecoder().decode(
      CursorUsageSummary.self,
      from: await responseData(request)
    )
  }

  private func fetchSand(cookie: String) async throws -> CursorSandUsage {
    var request = URLRequest(url: baseURL.appending(path: "api/dashboard/get-sand-usage-status"))
    request.httpMethod = "POST"
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{}".utf8)
    return try JSONDecoder().decode(CursorSandUsage.self, from: await responseData(request))
  }

  private func fetchUser(cookie: String) async throws -> CursorUserInfo {
    var request = URLRequest(url: baseURL.appending(path: "api/auth/me"))
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return try JSONDecoder().decode(CursorUserInfo.self, from: await responseData(request))
  }

  private func responseData(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await BoundedHTTPResponse.data(
      for: request,
      using: urlSession,
      maximumBytes: 4 * 1_024 * 1_024
    )
    guard let response = response as? HTTPURLResponse else {
      throw CursorAccountClientError.invalidResponse
    }
    if response.statusCode == 401 || response.statusCode == 403 {
      throw CursorAccountClientError.rejected
    }
    guard response.statusCode == 200 else {
      throw CursorAccountClientError.invalidResponse
    }
    return data
  }

  private static func jwtPayload(_ token: String) throws -> [String: Any] {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { throw CursorAccountClientError.invalidToken }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CursorAccountClientError.invalidToken
    }
    return object
  }

  private static func sqliteValue(database: URL, key: String) throws -> String? {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let connection else {
      if let connection { sqlite3_close(connection) }
      throw CursorAccountClientError.invalidResponse
    }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 250)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      connection,
      "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw CursorAccountClientError.invalidResponse
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    if sqlite3_column_type(statement, 0) == SQLITE_TEXT,
       let value = sqlite3_column_text(statement, 0) {
      return String(cString: value)
    }
    guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
          let bytes = sqlite3_column_blob(statement, 0) else { return nil }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    return String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16LittleEndian)
  }

  private static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = try? Date.ISO8601FormatStyle(
      includingFractionalSeconds: true
    ).parse(value) {
      return date
    }
    return try? Date.ISO8601FormatStyle(
      includingFractionalSeconds: false
    ).parse(value)
  }

  private static func windowMinutes(start: Date?, end: Date?) -> Int? {
    guard let start, let end, end > start else { return nil }
    return Int(end.timeIntervalSince(start) / 60)
  }

  private static func amountMicros(cents: Int) -> Int64 {
    let value = max(0, Int64(cents))
    return min(value, Int64.max / 10_000) * 10_000
  }
}

private struct CursorUsageEventsPage: Decodable {
  let totalUsageEventsCount: Int?
  let usageEventsDisplay: [CursorUsageEvent]
}

private struct CursorUsageEvent: Decodable {
  let timestamp: Date?
  let model: String?
  let tokenUsage: CursorEventTokenUsage?
  let isHeadless: Bool?

  private enum CodingKeys: String, CodingKey {
    case timestamp, model, tokenUsage, isHeadless
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try? container.decode(Int64.self, forKey: .timestamp) {
      timestamp = Date(timeIntervalSince1970: Double(value) / 1_000)
    } else if let value = try? container.decode(String.self, forKey: .timestamp),
              let milliseconds = Int64(value) {
      timestamp = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    } else {
      timestamp = nil
    }
    model = try? container.decode(String.self, forKey: .model)
    tokenUsage = try? container.decode(CursorEventTokenUsage.self, forKey: .tokenUsage)
    isHeadless = try? container.decode(Bool.self, forKey: .isHeadless)
  }
}

private struct CursorEventTokenUsage: Decodable {
  let inputTokens: Int
  let outputTokens: Int
  let cacheWriteTokens: Int
  let cacheReadTokens: Int
  let totalCents: Double?

  var isPlausible: Bool {
    [inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens].allSatisfy {
      (0...Int(UsageIngestionLimits.tokenCount)).contains($0)
    }
  }

  var totalTokens: Int64 {
    [inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens].reduce(Int64(0)) {
      $0 + Int64($1)
    }
  }

  var validTotalCents: Double? {
    totalCents.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = Self.int(container, .inputTokens)
    outputTokens = Self.int(container, .outputTokens)
    cacheWriteTokens = Self.int(container, .cacheWriteTokens)
    cacheReadTokens = Self.int(container, .cacheReadTokens)
    totalCents = Self.double(container, .totalCents)
  }

  private static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int {
    (try? container.decode(Int.self, forKey: key))
      ?? (try? container.decode(String.self, forKey: key)).flatMap(Int.init)
      ?? 0
  }

  private static func double<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    _ key: K
  ) -> Double? {
    (try? container.decode(Double.self, forKey: key))
      ?? (try? container.decode(String.self, forKey: key)).flatMap(Double.init)
  }
}

private struct CursorUsageSummary: Decodable {
  let billingCycleStart: String?
  let billingCycleEnd: String?
  let individualUsage: Individual?
  let teamUsage: Team?

  struct Individual: Decodable {
    let plan: Amount?
    let overall: Amount?
    let onDemand: Amount?
  }
  struct Team: Decodable {
    let pooled: Amount?
    let onDemand: Amount?
  }
  struct Amount: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let totalPercentUsed: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
  }
}

private struct CursorSandUsage: Decodable {
  let currentPeriodStart: String?
  let nextResetTimestampUtc: String?
  let usagePercent: Double?
  let hasNonZeroIncludedLimit: Bool?
}

private struct CursorUserInfo: Decodable {
  let email: String?
}
