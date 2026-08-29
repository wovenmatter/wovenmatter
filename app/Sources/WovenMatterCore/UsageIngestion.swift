import Foundation

/// The shared, append-only contract used by Woven Matter and local Buzz
/// workspaces. A cursor is opaque to clients and advances only
/// after every preceding event has been durably persisted by the producer.
public enum UsageIngestionProtocolName {
  public static let version = "wovenmatter.usage-ingestion.v1"
}

public enum UsageIngestionLimits {
  public static let eventsPerPage = 100
  public static let identifierBytes = 1_024
  public static let labelBytes = 4_096
  public static let tokenCount: Int64 = 1_000_000_000_000_000
  public static let requestCount = 1_000_000_000
  public static let costUSD = 1_000_000_000_000.0
}

public enum UsageIngestionSourceKind: String, Codable, Equatable, Sendable {
  case wovenMatter = "woven-matter"
  case buzzWorkspace = "buzz-workspace"
}

public struct UsageIngestionSource: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: UsageIngestionSourceKind
  public let location: String
  public let installationID: String

  public init(
    id: String,
    displayName: String,
    kind: UsageIngestionSourceKind,
    location: String,
    installationID: String
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.location = location
    self.installationID = installationID
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case kind
    case location
    case installationID = "installation_id"
  }
}

/// One settled usage observation. Producers may send the same event again or
/// correct it in place; `id` is stable within a source and Woven Matter uses
/// `(source.id, event.id)` as the idempotency key.
public struct UsageIngestionEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let sequence: Int64
  public let timestamp: Date
  public let provider: ProviderKind
  public let accountLabel: String
  public let billingProvider: String?
  public let billingRoute: String?
  public let model: String
  public let reasoningLevel: String?
  public let harness: String
  public let application: String
  public let agent: String?
  public let workspace: String?
  public let sessionID: String
  public let runID: String?
  public let tokens: UsageTokenCounts
  public let requestCount: Int
  public let costUSD: Double?
  public let attributionConfidence: UsageAttributionConfidence
  public let granularity: UsageGranularity
  public let dedupeKey: String?

  public init(
    id: String,
    sequence: Int64,
    timestamp: Date,
    provider: ProviderKind,
    accountLabel: String,
    billingProvider: String? = nil,
    billingRoute: String? = nil,
    model: String,
    reasoningLevel: String? = nil,
    harness: String,
    application: String,
    agent: String? = nil,
    workspace: String? = nil,
    sessionID: String,
    runID: String? = nil,
    tokens: UsageTokenCounts,
    requestCount: Int = 1,
    costUSD: Double? = nil,
    attributionConfidence: UsageAttributionConfidence = .exact,
    granularity: UsageGranularity = .turn,
    dedupeKey: String? = nil
  ) {
    self.id = id
    self.sequence = max(1, sequence)
    self.timestamp = timestamp
    self.provider = provider
    self.accountLabel = accountLabel
    self.billingProvider = billingProvider
    self.billingRoute = billingRoute
    self.model = model
    self.reasoningLevel = reasoningLevel
    self.harness = harness
    self.application = application
    self.agent = agent
    self.workspace = workspace
    self.sessionID = sessionID
    self.runID = runID
    self.tokens = tokens
    self.requestCount = max(1, requestCount)
    self.costUSD = costUSD
    self.attributionConfidence = attributionConfidence
    self.granularity = granularity
    self.dedupeKey = dedupeKey
  }

  public func sample(sourceID: String) -> UsageSample {
    UsageSample(
      id: "\(sourceID):\(id)",
      provider: provider,
      timestamp: timestamp,
      sessionID: sessionID,
      accountLabel: accountLabel,
      model: model,
      billingProvider: billingProvider,
      billingRoute: billingRoute,
      reasoningLevel: reasoningLevel,
      harness: harness,
      application: application,
      agent: agent,
      workspace: workspace,
      tokens: tokens,
      requestCount: requestCount,
      costUSD: costUSD,
      attributionConfidence: attributionConfidence,
      granularity: granularity,
      sourceID: sourceID,
      sourceEventID: id,
      dedupeKey: dedupeKey
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, sequence, timestamp, provider, model, harness, application, agent, workspace, tokens
    case accountLabel = "account_label"
    case billingProvider = "billing_provider"
    case billingRoute = "billing_route"
    case reasoningLevel = "reasoning_level"
    case sessionID = "session_id"
    case runID = "run_id"
    case requestCount = "request_count"
    case costUSD = "cost_usd"
    case attributionConfidence = "attribution_confidence"
    case granularity
    case dedupeKey = "dedupe_key"
  }
}

public struct UsageIngestionPage: Codable, Equatable, Sendable {
  public let protocolName: String
  public let source: UsageIngestionSource
  public let events: [UsageIngestionEvent]
  public let nextCursor: String
  public let hasMore: Bool
  public let generatedAt: Date

  public init(
    protocolName: String = UsageIngestionProtocolName.version,
    source: UsageIngestionSource,
    events: [UsageIngestionEvent],
    nextCursor: String,
    hasMore: Bool,
    generatedAt: Date = Date()
  ) {
    self.protocolName = protocolName
    self.source = source
    self.events = events
    self.nextCursor = nextCursor
    self.hasMore = hasMore
    self.generatedAt = generatedAt
  }

  public func validate(after cursor: String?) throws {
    guard protocolName == UsageIngestionProtocolName.version,
          Self.valid(source.id, maximumBytes: UsageIngestionLimits.identifierBytes),
          Self.valid(source.displayName, maximumBytes: UsageIngestionLimits.labelBytes),
          Self.valid(source.location, maximumBytes: UsageIngestionLimits.labelBytes),
          Self.valid(source.installationID, maximumBytes: UsageIngestionLimits.identifierBytes),
          events.count <= UsageIngestionLimits.eventsPerPage,
          let next = Int64(nextCursor), next >= 0 else {
      throw UsageIngestionError.invalidPage
    }
    let previous: Int64
    if let cursor {
      guard let parsed = Int64(cursor), parsed >= 0 else {
        throw UsageIngestionError.invalidPage
      }
      previous = parsed
    } else {
      previous = 0
    }
    var sequence = previous
    for event in events {
      let tokenValues = [
        event.tokens.inputTokens,
        event.tokens.cachedInputTokens,
        event.tokens.cacheCreationTokens,
        event.tokens.outputTokens,
        event.tokens.reasoningTokens,
      ] + (event.tokens.reportedTotalTokens.map { [$0] } ?? [])
      guard Self.valid(event.id, maximumBytes: UsageIngestionLimits.identifierBytes),
            Self.valid(event.accountLabel, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.valid(event.model, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.valid(event.harness, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.valid(event.application, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.valid(event.sessionID, maximumBytes: UsageIngestionLimits.identifierBytes),
            Self.validOptional(event.billingProvider, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.validOptional(event.billingRoute, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.validOptional(event.reasoningLevel, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.validOptional(event.agent, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.validOptional(event.workspace, maximumBytes: UsageIngestionLimits.labelBytes),
            Self.validOptional(event.runID, maximumBytes: UsageIngestionLimits.identifierBytes),
            Self.validOptional(event.dedupeKey, maximumBytes: UsageIngestionLimits.labelBytes),
            event.sequence > sequence,
            event.timestamp.timeIntervalSinceReferenceDate.isFinite,
            (1...UsageIngestionLimits.requestCount).contains(event.requestCount),
            tokenValues.allSatisfy({ (0...UsageIngestionLimits.tokenCount).contains($0) }),
            event.costUSD.map({ $0.isFinite && (0...UsageIngestionLimits.costUSD).contains($0) }) ?? true else {
        throw UsageIngestionError.invalidPage
      }
      sequence = event.sequence
    }
    guard next == sequence,
          !hasMore || !events.isEmpty else {
      throw UsageIngestionError.invalidPage
    }
  }

  private static func valid(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
  }

  private static func validOptional(_ value: String?, maximumBytes: Int) -> Bool {
    value.map { valid($0, maximumBytes: maximumBytes) } ?? true
  }

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case source, events
    case nextCursor = "next_cursor"
    case hasMore = "has_more"
    case generatedAt = "generated_at"
  }
}

public enum UsageIngestionError: LocalizedError, Equatable, Sendable {
  case invalidPage

  public var errorDescription: String? {
    switch self {
    case .invalidPage: "The usage source returned an invalid replay page."
    }
  }
}
