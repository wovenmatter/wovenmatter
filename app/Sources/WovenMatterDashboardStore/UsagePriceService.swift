import Foundation
import WovenMatterCore

public struct UsagePrices: Codable, Equatable, Sendable {
  public let table: UsageRateTable
  public let fetchedAt: Date

  public init(table: UsageRateTable, fetchedAt: Date) {
    self.table = table
    self.fetchedAt = fetchedAt
  }
}

/// Supplies model prices for the optional API estimate on Usage analytics.
/// It requests one public file and sends no usage, account or device data, and
/// nothing runs until the person turns the estimate on.
public actor UsagePriceService {
  public typealias Download = @Sendable () async throws -> Data

  public static let sourceURL = URL(
    string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  )!
  private static let maximumDocumentBytes = 32 * 1_024 * 1_024

  private let cacheURL: URL
  private let maximumAge: TimeInterval
  private let download: Download
  private let now: @Sendable () -> Date
  private var current: UsagePrices?
  private var didReadCache = false
  private var inFlight: Task<UsagePrices, any Error>?

  public init(
    cacheURL: URL = UsagePriceService.defaultCacheURL,
    maximumAge: TimeInterval = 24 * 60 * 60,
    download: @escaping Download = UsagePriceService.downloadDocument,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.cacheURL = cacheURL
    self.maximumAge = maximumAge
    self.download = download
    self.now = now
  }

  public nonisolated static var defaultCacheURL: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return caches
      .appending(path: Bundle.main.bundleIdentifier ?? "WovenMatter", directoryHint: .isDirectory)
      .appending(path: "usage-model-prices.json", directoryHint: .notDirectory)
  }

  /// Returns saved prices while they are fresh. A failed download keeps any older
  /// prices, so the estimate only becomes unavailable when none have ever loaded.
  public func prices(force: Bool = false) async throws -> UsagePrices {
    readCacheIfNeeded()
    if !force, let current, now().timeIntervalSince(current.fetchedAt) < maximumAge {
      return current
    }
    if let inFlight { return try await inFlight.value }
    let task = Task { [download, now] in
      let table = try UsageRateTable.parseLiteLLM(try await download())
      return UsagePrices(table: table, fetchedAt: now())
    }
    inFlight = task
    defer { inFlight = nil }
    do {
      let prices = try await task.value
      current = prices
      writeCache(prices)
      return prices
    } catch {
      if let current { return current }
      throw error
    }
  }

  private func readCacheIfNeeded() {
    guard !didReadCache else { return }
    didReadCache = true
    guard let data = try? Data(contentsOf: cacheURL),
          let prices = try? JSONDecoder().decode(UsagePrices.self, from: data) else { return }
    current = prices
  }

  private func writeCache(_ prices: UsagePrices) {
    // The cache only saves a repeat download, so failing to write it changes nothing else.
    guard let data = try? JSONEncoder().encode(prices) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: cacheURL, options: .atomic)
  }

  @Sendable public static func downloadDocument() async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: sourceURL)
    request.timeoutInterval = 30
    let (data, response) = try await session.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
      throw URLError(.badServerResponse)
    }
    guard data.count <= maximumDocumentBytes else {
      throw URLError(.dataLengthExceedsMaximum)
    }
    return data
  }
}
