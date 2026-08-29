import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex
  case claude
  case grok
  case cursor
  case openCodeGo = "opencode-go"
  case openRouter = "openrouter"
  case unknown

  public static let supportedAccounts: [ProviderKind] = [
    .codex, .claude, .grok, .cursor, .openCodeGo, .openRouter,
  ]

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codex: "Codex / OpenAI"
    case .claude: "Claude"
    case .grok: "Grok / xAI"
    case .cursor: "Cursor"
    case .openCodeGo: "OpenCode Go"
    case .openRouter: "OpenRouter"
    case .unknown: "Unknown"
    }
  }
}

public struct ProviderQuotaWindow: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let usedPercent: Double
  public let remainingPercent: Double
  public let usageKnown: Bool
  public let windowMinutes: Int?
  public let resetsAt: Date?
  public let resetDescription: String?

  public init(
    id: String,
    label: String,
    usedPercent: Double,
    usageKnown: Bool,
    windowMinutes: Int?,
    resetsAt: Date?,
    resetDescription: String? = nil
  ) {
    let clamped = min(100, max(0, usedPercent))
    self.id = id
    self.label = label
    self.usedPercent = clamped
    remainingPercent = 100 - clamped
    self.usageKnown = usageKnown
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
    self.resetDescription = resetDescription
  }
}

public struct ProviderMoney: Codable, Equatable, Sendable {
  public let amountMicros: Int64
  public let currency: String

  public init(amountMicros: Int64, currency: String) {
    self.amountMicros = max(0, amountMicros)
    self.currency = currency.uppercased()
  }
}

public struct ProviderReportedBudget: Codable, Equatable, Sendable {
  public let usedMicros: Int64
  public let limitMicros: Int64
  public let remainingMicros: Int64
  public let usedPercent: Double
  public let currency: String
  public let period: String?
  public let resetsAt: Date?
  public let scope: String

  public init(
    usedMicros: Int64,
    limitMicros: Int64,
    currency: String,
    period: String?,
    resetsAt: Date?,
    scope: String
  ) {
    self.usedMicros = max(0, usedMicros)
    self.limitMicros = max(0, limitMicros)
    remainingMicros = max(0, limitMicros - usedMicros)
    usedPercent = limitMicros > 0
      ? min(100, max(0, Double(usedMicros) / Double(limitMicros) * 100))
      : 0
    self.currency = currency.uppercased()
    self.period = period
    self.resetsAt = resetsAt
    self.scope = scope
  }
}
