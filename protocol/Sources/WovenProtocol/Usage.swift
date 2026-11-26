import Foundation

// Usage and dictation history: both synced, so any server answers for
// every machine from its own library. Usage covers every
// harness on every machine, inside Woven Matter or not: each server reads its
// own machine's harness histories into the library.

/// Tokens and cost summed by the server.
public struct UsageAmounts: Codable, Sendable, Hashable {
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64
  /// In US dollars, as the harness reported it; 0 when it reported none.
  public var cost: Double
  /// How many model responses (or, for Pi Durable, turns) the records are.
  public var requests: Int

  public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, cost: Double = 0, requests: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.cost = cost
    self.requests = requests
  }
}

/// Usage of one session with one model in one period, on one machine.
public struct UsageGroup: Codable, Sendable, Hashable {
  /// The start of the period the group falls in.
  public var period: Date
  /// The newest record in the group.
  public var latest: Date
  public var machineID: String
  /// The Woven Matter session, when the usage was one.
  public var sessionID: String?
  /// The harness's own session identifier, for usage read from its history.
  public var nativeSessionID: String?
  /// Whether the usage was made inside Woven Matter.
  public var inWoven: Bool
  public var runtime: RuntimeKind
  public var model: String
  public var amounts: UsageAmounts

  public init(period: Date, latest: Date, machineID: String, sessionID: String?, nativeSessionID: String?, inWoven: Bool,
              runtime: RuntimeKind, model: String, amounts: UsageAmounts) {
    self.period = period
    self.latest = latest
    self.machineID = machineID
    self.sessionID = sessionID
    self.nativeSessionID = nativeSessionID
    self.inWoven = inWoven
    self.runtime = runtime
    self.model = model
    self.amounts = amounts
  }
}

/// Usage in a range, from every machine's records in this library.
public struct UsageReport: Codable, Sendable, Hashable {
  public var groups: [UsageGroup]
  /// Everything in the range.
  public var totals: UsageAmounts
  /// Distinct sessions in the range, Woven Matter's and the harnesses' own.
  public var sessions: Int
  /// Each machine's newest record of all, by machine ID, so a machine whose
  /// usage has not arrived is not read as idle.
  public var newestByMachine: [String: Date]

  public init(groups: [UsageGroup], totals: UsageAmounts, sessions: Int, newestByMachine: [String: Date]) {
    self.groups = groups
    self.totals = totals
    self.sessions = sessions
    self.newestByMachine = newestByMachine
  }
}

/// Usage recorded from `start` up to `end`, summed per session, model and
/// period of `periodSeconds`.
public struct ReadUsage: Request {
  public static let method = "usage.read"
  public typealias Reply = UsageReport
  public var start: Date
  public var end: Date
  public var periodSeconds: Int
  /// A time zone identifier ("Europe/Paris"). With a period of a day, the
  /// periods are that zone's calendar days rather than UTC days.
  public var timeZone: String?

  public init(start: Date, end: Date, periodSeconds: Int, timeZone: String? = nil) {
    self.start = start
    self.end = end
    self.periodSeconds = periodSeconds
    self.timeZone = timeZone
  }
}

/// A provider account's limits as the provider reports them now.
public struct UsageLimit: Codable, Sendable, Hashable {
  public struct Window: Codable, Sendable, Hashable {
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
      self.label = label
      self.usedPercent = usedPercent
      self.windowMinutes = windowMinutes
      self.resetsAt = resetsAt
    }
  }

  /// "openai-codex" or "openrouter".
  public var provider: String
  public var accountLabel: String
  public var windows: [Window]
  /// Spent and limit in US dollars, for an account with a credit limit.
  public var spent: Double?
  public var limit: Double?
  /// Why the limits could not be read, when they could not.
  public var error: String?

  public init(provider: String, accountLabel: String, windows: [Window] = [], spent: Double? = nil, limit: Double? = nil,
              error: String? = nil) {
    self.provider = provider
    self.accountLabel = accountLabel
    self.windows = windows
    self.spent = spent
    self.limit = limit
    self.error = error
  }
}

/// The limits of the accounts this machine is signed in to. Live state of
/// the machine asked; nothing is stored.
public struct ReadUsageLimits: Request {
  public static let method = "usage.limits"
  public typealias Reply = [UsageLimit]
  public init() {}
}

/// US dollars per token for one model at public API list prices.
public struct ModelPrice: Codable, Sendable, Hashable {
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double

  public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }
}

public struct ModelPrices: Codable, Sendable, Hashable {
  /// By lowercased model identifier.
  public var prices: [String: ModelPrice]
  public var fetchedAt: Date

  public init(prices: [String: ModelPrice], fetchedAt: Date) {
    self.prices = prices
    self.fetchedAt = fetchedAt
  }
}

/// The public list-price table, which the server downloads and keeps for a day.
public struct ReadModelPrices: Request {
  public static let method = "usage.prices"
  public typealias Reply = ModelPrices
  /// Downloads it again now.
  public var refresh: Bool
  public init(refresh: Bool = false) { self.refresh = refresh }
}

// MARK: Dictation

/// One completed dictation.
public struct Dictation: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var machineID: String
  public var text: String
  public var recordedAt: Date

  public init(id: String, machineID: String, text: String, recordedAt: Date) {
    self.id = id
    self.machineID = machineID
    self.text = text
    self.recordedAt = recordedAt
  }
}

/// Saves a completed dictation. Saving the same `id` again changes nothing.
public struct SaveDictation: Request {
  public static let method = "dictation.save"
  public typealias Reply = Done
  public var id: String
  public var text: String
  public var recordedAt: Date

  public init(id: String, text: String, recordedAt: Date) {
    self.id = id
    self.text = text
    self.recordedAt = recordedAt
  }
}

/// Dictations from every machine, newest first.
public struct ListDictations: Request {
  public static let method = "dictation.list"
  public typealias Reply = [Dictation]
  public var limit: Int
  public var offset: Int

  public init(limit: Int, offset: Int) {
    self.limit = limit
    self.offset = offset
  }
}
