import Foundation

public struct LocalACPWorkspaceAvailability: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case ready
        case setupRequired = "setup_required"
        case invalidConfiguration = "invalid_configuration"
    }

    public let state: State
    public let detail: String
    public let rootPath: String?
    public let databasesPath: String?
    public var isReady: Bool { state == .ready }

    public init(state: State, detail: String, rootPath: String?, databasesPath: String? = nil) {
        self.state = state
        self.detail = detail
        self.rootPath = rootPath
        self.databasesPath = databasesPath
    }
}

public struct LocalACPWorkspaceLaunchConfiguration: Sendable {
    public let rootURL: URL
    /// Dataset storage belongs to Woven's service, independently of any project.
    public let databasesURL: URL

    public init(rootURL: URL, databasesURL: URL? = nil) {
        self.rootURL = rootURL
        self.databasesURL = databasesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Woven Matter/ManagedDatabases", isDirectory: true)
    }
}

public struct LocalACPWorkspaceResolution: Sendable {
    public let availability: LocalACPWorkspaceAvailability
    public let launchConfiguration: LocalACPWorkspaceLaunchConfiguration?

    public init(availability: LocalACPWorkspaceAvailability, launchConfiguration: LocalACPWorkspaceLaunchConfiguration?) {
        self.availability = availability
        self.launchConfiguration = launchConfiguration
    }
}

public enum LocalACPWorkspaceProvisioner {
    public static let rootDirectoryName = ".woven-matter"

    public static func createProject(named rawName: String, in root: URL) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.lowercased() != "scratch", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.utf8.count <= 255,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalACPWorkspaceError.invalidProjectName
        }
        let path = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw LocalACPWorkspaceError.projectAlreadyExists
        }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }

    /// The reservation is persisted by the session owner before this idempotent operation.
    public static func ensureScratchDirectory(at directory: URL, in workspace: URL) throws {
        let scratch = workspace.appendingPathComponent("scratch", isDirectory: true).standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.deletingLastPathComponent() == scratch, !target.lastPathComponent.hasPrefix("."),
              !target.lastPathComponent.isEmpty else { throw LocalACPWorkspaceError.invalidProjectName }
        for path in [scratch, target] {
            if !FileManager.default.fileExists(atPath: path.path) {
                do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { }
            }
            let info = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw LocalACPWorkspaceError.invalidProjectName }
        }
    }

    @discardableResult
    public static func ensureWorkspace(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

public actor LocalACPWorkspaceConfigurationStore {
    private let homeDirectory: URL
    private let databasesDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, databasesDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.databasesDirectory = databasesDirectory ?? homeDirectory.appendingPathComponent("Library/Application Support/Woven Matter/ManagedDatabases", isDirectory: true)
    }

    public func setUpWorkspace(in homeDirectory: URL) throws {
        guard homeDirectory.standardizedFileURL == self.homeDirectory.standardizedFileURL else {
            throw LocalACPWorkspaceError.selectHomeDirectory
        }
        try LocalACPWorkspaceProvisioner.ensureWorkspace(at: root)
    }

    private var root: URL {
        homeDirectory.appendingPathComponent(LocalACPWorkspaceProvisioner.rootDirectoryName, isDirectory: true)
    }

    public func resolve() -> LocalACPWorkspaceResolution {
        do {
            try LocalACPWorkspaceProvisioner.ensureWorkspace(at: root)
            let databases = databasesDirectory
            return .init(
                availability: .init(state: .ready, detail: "New folders create blank project directories.",
                    rootPath: root.path, databasesPath: databases.path),
                launchConfiguration: .init(rootURL: root, databasesURL: databases))
        } catch {
            return .init(availability: .init(state: .invalidConfiguration, detail: error.localizedDescription, rootPath: root.path),
                launchConfiguration: nil)
        }
    }
}

public enum LocalACPWorkspaceError: LocalizedError, Equatable, Sendable {
    case selectHomeDirectory
    case invalidProjectName
    case projectAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .selectHomeDirectory:
            "Woven Matter can create its managed workspace only in the current macOS home directory."
        case .invalidProjectName:
            "Use a directory name without slashes or a leading period. Scratch is reserved for Ungrouped chats."
        case .projectAlreadyExists:
            "A directory with that name already exists. Link it instead."
        }
    }
}
