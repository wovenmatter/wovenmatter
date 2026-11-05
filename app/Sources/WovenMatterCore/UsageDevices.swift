import CryptoKit
import Foundation

public enum UsageDeviceKind: String, Codable, Sendable {
  case mac
  case linux
  case ios
}

public struct UsageDeviceIdentity: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let kind: UsageDeviceKind

  public init(id: String, name: String, kind: UsageDeviceKind) {
    self.id = id
    self.name = name
    self.kind = kind
  }
}

public enum UsageDeviceSyncState: String, Codable, Sendable {
  case thisDevice
  case synced
  case scanning
  case waiting
  case updateRequired
  case unavailable
}

/// What the Usage page shows for one device. Stale or unreachable devices say so,
/// because missing usage must never read as zero.
public struct UsageDeviceSummary: Codable, Equatable, Identifiable, Sendable {
  public let identity: UsageDeviceIdentity
  public let state: UsageDeviceSyncState
  public let syncedAt: Date?
  public let detail: String?

  /// Matches `UsageSample.usageDeviceID`, so filters and totals find this device's rows.
  public var id: String { UsageDeviceSource.storedID(identity.id) }

  public init(
    identity: UsageDeviceIdentity,
    state: UsageDeviceSyncState,
    syncedAt: Date? = nil,
    detail: String? = nil
  ) {
    self.identity = identity
    self.state = state
    self.syncedAt = syncedAt
    self.detail = detail
  }
}

/// Usage from another device lives under a source ID naming that device.
public enum UsageDeviceSource {
  public static let localDeviceID = "local"
  private static let prefix = "device:"
  private static let liveRunsSuffix = ":wovenmatter:local"

  /// A device ID as stored, since `:` separates the parts of a source ID.
  public static func storedID(_ deviceID: String) -> String {
    deviceID.replacingOccurrences(of: ":", with: "-")
  }

  public static func sourceID(deviceID: String) -> String {
    prefix + storedID(deviceID)
  }

  public static func liveRunsSourceID(deviceID: String) -> String {
    sourceID(deviceID: deviceID) + liveRunsSuffix
  }

  public static func deviceID(fromSourceID sourceID: String) -> String? {
    guard sourceID.hasPrefix(prefix) else { return nil }
    return sourceID.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).first.map(String.init)
  }

  public static func isLiveRunSource(_ sourceID: String) -> Bool {
    sourceID.hasPrefix(prefix) && sourceID.hasSuffix(liveRunsSuffix)
  }
}

public extension UsageSample {
  /// The device that did this work. "local" is this Mac.
  var usageDeviceID: String {
    UsageDeviceSource.deviceID(fromSourceID: sourceID) ?? UsageDeviceSource.localDeviceID
  }

  /// A turn this Mac watched a remote workspace run, as opposed to the host's own history.
  var isRemoteLiveRun: Bool { UsageDeviceSource.isLiveRunSource(sourceID) }
}

public enum UsageDeviceCollectionError: Error, Equatable {
  case invalidPage
  case updateRequired
}

public struct UsageDeviceExportRequest: Codable, Equatable, Sendable {
  public let since: Double
  public let offset: Int

  public init(since: Double, offset: Int) {
    self.since = since
    self.offset = offset
  }
}

/// One hour of one session's usage on a device. Counts and labels only: this crosses
/// between devices, so it holds no transcript content, prompts or file paths.
public struct UsageDeviceRecord: Codable, Equatable, Sendable {
  public let id: String
  /// Set when a Mac passes on usage from a remote workspace it manages.
  public var device: String?
  public let timestamp: Double
  public let provider: String
  public let sessionID: String
  public let accountLabel: String
  public let model: String
  public let billingProvider: String
  public let billingRoute: String
  public let reasoningLevel: String?
  public let harness: String
  public let application: String
  public let agent: String?
  public let workspace: String?
  public let inputTokens: Int64
  public let cachedInputTokens: Int64
  public let cacheCreationTokens: Int64
  public let outputTokens: Int64
  public let reasoningTokens: Int64
  public let totalTokens: Int64?
  public let requestCount: Int
  public let costUSD: Double?
  public let dedupeKey: String?

  public init(sample: UsageSample) {
    // Hashed because a source ID can hold a transcript's full path.
    id = SHA256.hash(data: Data((sample.sourceID + ":" + sample.sourceEventID).utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
    device = sample.usageDeviceID == UsageDeviceSource.localDeviceID ? nil : sample.usageDeviceID
    timestamp = sample.timestamp.timeIntervalSince1970
    provider = sample.provider.rawValue
    sessionID = sample.sessionID
    accountLabel = sample.accountLabel
    model = sample.model
    billingProvider = sample.billingProvider
    billingRoute = sample.billingRoute
    reasoningLevel = sample.reasoningLevel
    harness = sample.harness
    application = sample.application
    agent = sample.agent
    // Never a full path, which can name private folders.
    workspace = sample.workspace.map { URL(fileURLWithPath: $0).lastPathComponent }
    inputTokens = sample.tokens.inputTokens
    cachedInputTokens = sample.tokens.cachedInputTokens
    cacheCreationTokens = sample.tokens.cacheCreationTokens
    outputTokens = sample.tokens.outputTokens
    reasoningTokens = sample.tokens.reasoningTokens
    totalTokens = sample.tokens.reportedTotalTokens
    requestCount = sample.requestCount
    costUSD = sample.costUSD
    dedupeKey = sample.dedupeKey
  }

  /// Another device's data is untrusted, so anything out of bounds is dropped.
  public func sample(deviceID: String) -> UsageSample? {
    let labels = [id, sessionID, accountLabel, model, billingProvider, billingRoute, harness, application]
      + [reasoningLevel, agent, workspace, dedupeKey].compactMap { $0 }
    guard timestamp.isFinite, timestamp >= 0,
          labels.allSatisfy({ $0.utf8.count <= UsageIngestionLimits.labelBytes }),
          !id.isEmpty else { return nil }
    let counts = [inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens, reasoningTokens, totalTokens ?? 0]
    guard counts.allSatisfy({ (0...UsageIngestionLimits.tokenCount).contains($0) }),
          (0...UsageIngestionLimits.requestCount).contains(requestCount),
          costUSD.map({ $0.isFinite && (0...UsageIngestionLimits.costUSD).contains($0) }) ?? true else { return nil }
    let sourceID = UsageDeviceSource.sourceID(deviceID: deviceID)
    return UsageSample(
      id: sourceID + ":" + id,
      provider: ProviderKind(rawValue: provider) ?? .unknown,
      timestamp: Date(timeIntervalSince1970: timestamp),
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
      tokens: UsageTokenCounts(
        inputTokens: inputTokens,
        cachedInputTokens: cachedInputTokens,
        cacheCreationTokens: cacheCreationTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        reportedTotalTokens: totalTokens
      ),
      requestCount: requestCount,
      costUSD: costUSD,
      granularity: .sessionAggregate,
      sourceID: sourceID,
      sourceEventID: id,
      dedupeKey: dedupeKey
    )
  }
}

public struct UsageDeviceExportPage: Codable, Equatable, Sendable {
  public static let maximumRecords = 2_000

  public enum State: String, Codable, Sendable {
    case ready
    /// A remote host is still reading its history. Ask again later.
    case scanning
  }

  public let state: State
  public let generatedAt: Double
  public let records: [UsageDeviceRecord]
  public let hasMore: Bool
  public let nextOffset: Int
  /// Remote workspaces whose usage this device is passing on.
  public let devices: [UsageDeviceIdentity]?

  public init(
    state: State,
    generatedAt: Double,
    records: [UsageDeviceRecord],
    hasMore: Bool,
    nextOffset: Int,
    devices: [UsageDeviceIdentity]? = nil
  ) {
    self.state = state
    self.generatedAt = generatedAt
    self.records = records
    self.hasMore = hasMore
    self.nextOffset = nextOffset
    self.devices = devices
  }
}

public extension UsageDeviceExportPage {
  /// One bounded page of records that are already in memory.
  static func paged(_ records: [UsageDeviceRecord], request: UsageDeviceExportRequest, now: Date = Date()) -> Self {
    let offset = max(0, request.offset)
    let page = records.dropFirst(offset).prefix(maximumRecords)
    return .init(
      state: .ready,
      generatedAt: now.timeIntervalSince1970,
      records: Array(page),
      hasMore: offset + page.count < records.count,
      nextOffset: offset + page.count
    )
  }
}

/// One device this Mac can read usage from.
public struct UsageDeviceEndpoint: Sendable {
  public let identity: UsageDeviceIdentity
  /// Set for sources without a usable time filter, such as records already on this Mac.
  public let alwaysFull: Bool
  /// Set when the device keeps its own lasting index, so its report is complete even
  /// after the original files are gone. Row IDs from other devices must stay stable.
  public let keepsLastingHistory: Bool
  /// Devices this Mac reads directly, so a relayed copy of them is ignored.
  public let excludedRelays: Set<String>
  public let fetch: @Sendable (UsageDeviceExportRequest) async throws -> UsageDeviceExportPage

  public init(
    identity: UsageDeviceIdentity,
    alwaysFull: Bool = false,
    keepsLastingHistory: Bool = false,
    excludedRelays: Set<String> = [],
    fetch: @escaping @Sendable (UsageDeviceExportRequest) async throws -> UsageDeviceExportPage
  ) {
    self.identity = identity
    self.alwaysFull = alwaysFull
    self.keepsLastingHistory = keepsLastingHistory
    self.excludedRelays = excludedRelays
    self.fetch = fetch
  }
}
