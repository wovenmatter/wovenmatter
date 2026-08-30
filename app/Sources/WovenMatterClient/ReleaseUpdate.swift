import Foundation

public struct WovenMatterReleaseVersion: Comparable, Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init?(_ value: String) {
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 3,
          let major = Int(pieces[0]),
          let minor = Int(pieces[1]),
          let patch = Int(pieces[2]),
          major >= 0,
          minor >= 0,
          patch >= 0,
          pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public struct WovenMatterReleaseManifest: Decodable, Equatable, Sendable {
  public let schemaVersion: Int
  public let version: String
  public let build: Int
  public let architecture: String
  public let minimumMacOS: String
  public let downloadURL: URL
  public let releaseURL: URL
  public let sha256: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case version
    case build
    case architecture
    case minimumMacOS = "minimum_macos"
    case downloadURL = "download_url"
    case releaseURL = "release_url"
    case sha256
  }

  public func validated() throws -> Self {
    guard schemaVersion == 1,
          WovenMatterReleaseVersion(version) != nil,
          build > 0,
          architecture == "arm64",
          downloadURL.scheme == "https",
          downloadURL.host == "github.com",
          releaseURL.scheme == "https",
          releaseURL.host == "github.com",
          sha256.count == 64,
          sha256.allSatisfy(\.isHexDigit) else {
      throw WovenMatterReleaseUpdateError.invalidManifest
    }
    let expectedAsset = "WovenMatter_\(version)_arm64.dmg"
    guard downloadURL.lastPathComponent == expectedAsset,
          downloadURL.path.contains("/wovenmatter/wovenmatter/releases/download/v\(version)/"),
          releaseURL.path == "/wovenmatter/wovenmatter/releases/tag/v\(version)" else {
      throw WovenMatterReleaseUpdateError.invalidManifest
    }
    return self
  }
}

public enum WovenMatterReleaseUpdateResult: Equatable, Sendable {
  case current
  case available(WovenMatterReleaseManifest)
}

public enum WovenMatterReleaseUpdateError: LocalizedError, Equatable, Sendable {
  case invalidCurrentVersion
  case invalidManifest
  case invalidResponse
  case responseTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidCurrentVersion:
      "The installed Woven Matter version is invalid."
    case .invalidManifest:
      "The Woven Matter release manifest is invalid."
    case .invalidResponse:
      "GitHub did not return the Woven Matter release manifest."
    case .responseTooLarge:
      "The Woven Matter release manifest exceeded its size limit."
    }
  }
}

public struct WovenMatterReleaseUpdateClient: Sendable {
  public static let manifestURL = URL(
    string: "https://github.com/wovenmatter/wovenmatter/releases/latest/download/latest-mac.json"
  )!
  public static let maximumManifestBytes = 64 * 1_024

  public typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

  private let fetch: Fetch

  public init(fetch: @escaping Fetch = { url in
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 20
    return try await URLSession.shared.data(for: request)
  }) {
    self.fetch = fetch
  }

  public func check(currentVersion: String) async throws -> WovenMatterReleaseUpdateResult {
    guard let current = WovenMatterReleaseVersion(currentVersion) else {
      throw WovenMatterReleaseUpdateError.invalidCurrentVersion
    }
    let (data, response) = try await fetch(Self.manifestURL)
    guard let http = response as? HTTPURLResponse,
          http.statusCode == 200,
          http.url?.scheme == "https",
          data.count <= Self.maximumManifestBytes else {
      if data.count > Self.maximumManifestBytes {
        throw WovenMatterReleaseUpdateError.responseTooLarge
      }
      throw WovenMatterReleaseUpdateError.invalidResponse
    }
    let manifest: WovenMatterReleaseManifest
    do {
      manifest = try JSONDecoder().decode(WovenMatterReleaseManifest.self, from: data)
    } catch {
      throw WovenMatterReleaseUpdateError.invalidManifest
    }
    let validated = try manifest.validated()
    guard let available = WovenMatterReleaseVersion(validated.version) else {
      throw WovenMatterReleaseUpdateError.invalidManifest
    }
    return available > current ? .available(validated) : .current
  }
}
