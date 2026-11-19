import Foundation

public struct HarnessCatalogDocument: Codable, Equatable, Sendable {
  public let harnesses: [HarnessDefinition]

  public init(harnesses: [HarnessDefinition]) {
    self.harnesses = harnesses
  }
}

public struct HarnessDefinition: Codable, Equatable, Identifiable, Sendable {
  public struct Installation: Codable, Equatable, Sendable {
    public let kind: String
    public let source: URL
    public let command: String
    public let interpreter: String?
    public let arguments: [String]
    public let package: String?
  }

  /// The vendor's own update command for an installed CLI, run in the person's login shell.
  public struct Update: Codable, Equatable, Sendable {
    public let command: String
    public let arguments: [String]
  }

  public struct Authentication: Codable, Equatable, Sendable {
    public struct Discovery: Codable, Equatable, Sendable {
      public let displayName: String
      public let statusCommand: String
    }

    public struct Method: Codable, Equatable, Identifiable, Sendable {
      public let id: String
      public let displayName: String
      public let kind: String
      public let command: String
      public let acceptsInput: Bool
      public let inputLabel: String?
      public let inputSecret: Bool?
      public let verificationURL: URL?
      public let notice: String?
    }

    public let statusCommands: [String]
    public let discoveries: [Discovery]
    public let methods: [Method]
  }

  public let id: AgentRuntimeKind
  public let displayName: String
  public let transport: String
  public let command: String
  public let arguments: [String]
  public let cliCommand: String
  public let adapterPackage: String?
  public let transportCheckCommand: String?
  public let install: Installation
  public let update: Update?
  public let authentication: Authentication
  public let capabilities: [String]
}

public enum HarnessCatalog {
  public static func load(from url: URL) throws -> HarnessCatalogDocument {
    let document = try JSONDecoder().decode(
      HarnessCatalogDocument.self,
      from: Data(contentsOf: url)
    )
    guard document.harnesses.count == AgentRuntimeKind.allCases.filter({ $0 != .defaultAgent }).count,
          Set(document.harnesses.map(\.id)) == Set(AgentRuntimeKind.allCases.filter { $0 != .defaultAgent })
    else {
      throw HarnessCatalogError.incompleteCatalog
    }
    return document
  }

  private static let hostCatalogLock = NSLock()
  nonisolated(unsafe) private static var configuredHostCatalog: URL?
  /// A host without an app bundle (`wovenmatter-library`) names the catalog
  /// its release ships. Set it before the first catalog read.
  public static var hostCatalogURL: URL? {
    get { hostCatalogLock.withLock { configuredHostCatalog } }
    set { hostCatalogLock.withLock { configuredHostCatalog = newValue } }
  }

  public static func loadBundled() throws -> HarnessCatalogDocument {
    let fileManager = FileManager.default
    let currentDirectory = URL(
      fileURLWithPath: fileManager.currentDirectoryPath,
      isDirectory: true
    )
    let candidates = [
      hostCatalogURL,
      Bundle.main.resourceURL?.appending(path: "harnesses/catalog.json"),
      currentDirectory.appending(path: "harnesses/catalog.json"),
      currentDirectory.appending(path: "../harnesses/catalog.json"),
    ].compactMap { $0 }
    guard let url = candidates.first(where: {
      fileManager.isReadableFile(atPath: $0.path)
    }) else {
      throw HarnessCatalogError.unavailable
    }
    return try load(from: url)
  }
}

public enum HarnessCatalogError: LocalizedError, Equatable, Sendable {
  case unavailable
  case incompleteCatalog

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "The shared harness catalog is unavailable."
    case .incompleteCatalog:
      "The harness catalog must contain each supported harness exactly once."
    }
  }
}
