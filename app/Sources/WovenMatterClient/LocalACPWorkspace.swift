import Foundation

public struct LocalACPWorkspaceAvailability: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready
        case setupRequired = "setup_required"
        case invalidConfiguration = "invalid_configuration"
    }

    public let state: State
    public let detail: String
    public let rootPath: String?
    public let repositoriesPath: String?
    public let databasesPath: String?
    public let usesExternalRepositories: Bool
    public let usesExternalDatabases: Bool

    public var isReady: Bool { state == .ready }

    public init(
        state: State,
        detail: String,
        rootPath: String?,
        repositoriesPath: String?,
        databasesPath: String? = nil,
        usesExternalRepositories: Bool,
        usesExternalDatabases: Bool = false
    ) {
        self.state = state
        self.detail = detail
        self.rootPath = rootPath
        self.repositoriesPath = repositoriesPath
        self.databasesPath = databasesPath
        self.usesExternalRepositories = usesExternalRepositories
        self.usesExternalDatabases = usesExternalDatabases
    }
}

public struct LocalACPWorkspaceLaunchConfiguration: Sendable {
    public let rootURL: URL
    public let repositoriesURL: URL
    public let databasesURL: URL

    public init(
        rootURL: URL,
        repositoriesURL: URL,
        databasesURL: URL? = nil
    ) {
        self.rootURL = rootURL
        self.repositoriesURL = repositoriesURL
        self.databasesURL = databasesURL ?? rootURL.appending(
            path: LocalACPWorkspaceProvisioner.databasesDirectoryName,
            directoryHint: .isDirectory
        )
    }
}

public struct LocalACPWorkspaceResolution: Sendable {
    public let availability: LocalACPWorkspaceAvailability
    public let launchConfiguration: LocalACPWorkspaceLaunchConfiguration?

    public init(
        availability: LocalACPWorkspaceAvailability,
        launchConfiguration: LocalACPWorkspaceLaunchConfiguration?
    ) {
        self.availability = availability
        self.launchConfiguration = launchConfiguration
    }
}

public enum LocalACPWorkspaceProvisioner {
    public static let rootDirectoryName = ".woven-matter"
    public static let repositoriesDirectoryName = "REPOS"
    public static let databasesDirectoryName = "Databases"
    public static let knowledgeDirectories = [
        "GUIDES",
        "PLANS",
        "RESEARCH",
        "WORK_LOGS",
        "OUTBOX",
        ".scratch",
    ]

    public static func ensureWorkspace(
        at rootURL: URL,
        repositoriesURL: URL?,
        databasesURL: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        if try isSymbolicLink(root) {
            throw LocalACPWorkspaceError.workspaceRootIsSymbolicLink
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try setOwnerOnlyDirectoryPermissions(root)

        try SharedWorkspaceInitializer.run(at: root)
        _ = try reconcileDatabases(
            at: root.appending(
                path: databasesDirectoryName,
                directoryHint: .isDirectory
            ),
            workspaceRoot: root,
            externalDatabasesURL: databasesURL
        )
        return try reconcileRepositories(
            at: root.appending(
                path: repositoriesDirectoryName,
                directoryHint: .isDirectory
            ),
            workspaceRoot: root,
            externalRepositoriesURL: repositoriesURL
        )
    }

    private static func reconcileRepositories(
        at repositoriesLink: URL,
        workspaceRoot: URL,
        externalRepositoriesURL: URL?
    ) throws -> URL {
        try reconcileDirectory(
            at: repositoriesLink,
            externalURL: externalRepositoriesURL,
            nonemptyDirectoryError: .defaultRepositoriesNotEmpty
        ) { try validateRepositoriesDirectory($0, workspaceRoot: workspaceRoot) }
    }

    private static func reconcileDatabases(
        at databasesLink: URL,
        workspaceRoot: URL,
        externalDatabasesURL: URL?
    ) throws -> URL {
        try reconcileDirectory(
            at: databasesLink,
            externalURL: externalDatabasesURL,
            nonemptyDirectoryError: .defaultDatabasesNotEmpty
        ) { try validateDatabasesDirectory($0, workspaceRoot: workspaceRoot) }
    }

    private static func reconcileDirectory(
        at link: URL,
        externalURL: URL?,
        nonemptyDirectoryError: LocalACPWorkspaceError,
        validateTarget: (URL) throws -> URL
    ) throws -> URL {
        let fileManager = FileManager.default
        guard let externalURL else {
            if try isSymbolicLink(link) {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createDirectory(
                at: link,
                withIntermediateDirectories: true
            )
            try setOwnerOnlyDirectoryPermissions(link)
            return link
        }

        let target = try validateTarget(externalURL)
        if fileManager.fileExists(atPath: link.path)
            || (try? isSymbolicLink(link)) == true {
            if try isSymbolicLink(link) {
                let destination = try fileManager.destinationOfSymbolicLink(
                    atPath: link.path
                )
                let destinationURL = URL(
                    fileURLWithPath: destination,
                    relativeTo: link.deletingLastPathComponent()
                ).standardizedFileURL
                if destinationURL.resolvingSymlinksInPath() == target {
                    return target
                }
                try fileManager.removeItem(at: link)
            } else {
                guard try isEmptyDirectory(link) else {
                    throw nonemptyDirectoryError
                }
                try fileManager.removeItem(at: link)
            }
        }
        try fileManager.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        return target
    }

    private static func validateRepositoriesDirectory(
        _ url: URL,
        workspaceRoot: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LocalACPWorkspaceError.repositoriesDirectoryUnavailable
        }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        if root == target || root.path.hasPrefix(target.path + "/") {
            throw LocalACPWorkspaceError.repositoriesDirectoryContainsWorkspace
        }
        return target
    }

    private static func validateDatabasesDirectory(
        _ url: URL,
        workspaceRoot: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LocalACPWorkspaceError.databasesDirectoryUnavailable
        }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        if root == target || root.path.hasPrefix(target.path + "/") {
            throw LocalACPWorkspaceError.databasesDirectoryContainsWorkspace
        }
        return target
    }

    private static func isEmptyDirectory(_ url: URL) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        return contents.isEmpty
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.destinationOfSymbolicLinkIfPresent(at: url) != nil
        else {
            return false
        }
        return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    private static func setOwnerOnlyDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

public actor LocalACPWorkspaceConfigurationStore {
    private struct StoredConfiguration: Codable, Sendable {
        let repositoriesPath: String?
        let databasesPath: String?

        init(repositoriesPath: String?, databasesPath: String? = nil) {
            self.repositoriesPath = repositoriesPath
            self.databasesPath = databasesPath
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let homeDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaultsSuiteName: String? = nil,
        storageKey: String = "wovenmatter.local-agent-workspace.folders"
    ) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        self.storageKey = storageKey
        self.homeDirectory = homeDirectory
    }

    public func setUpWorkspace(in homeDirectory: URL) throws {
        let selectedHome = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let expectedHome = self.homeDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard selectedHome == expectedHome else {
            throw LocalACPWorkspaceError.selectHomeDirectory
        }
        let root = selectedHome.appending(
            path: LocalACPWorkspaceProvisioner.rootDirectoryName,
            directoryHint: .isDirectory
        )
        let stored = try load()
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(
            at: root,
            repositoriesURL: stored?.repositoriesPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            databasesURL: stored?.databasesPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        )
    }

    public func configureRepositories(_ repositoriesURL: URL?) throws {
        let home = homeDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = home.appending(
            path: LocalACPWorkspaceProvisioner.rootDirectoryName,
            directoryHint: .isDirectory
        )
        let repositories = repositoriesURL.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        let stored = try load()
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(
            at: root,
            repositoriesURL: repositories,
            databasesURL: stored?.databasesPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        )
        try save(StoredConfiguration(
            repositoriesPath: repositories?.path,
            databasesPath: stored?.databasesPath
        ))
    }

    public func configureDatabases(_ databasesURL: URL?) throws {
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let root = home.appending(
            path: LocalACPWorkspaceProvisioner.rootDirectoryName,
            directoryHint: .isDirectory
        )
        let databases = databasesURL.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        let stored = try load()
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(
            at: root,
            repositoriesURL: stored?.repositoriesPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            databasesURL: databases
        )
        try save(StoredConfiguration(
            repositoriesPath: stored?.repositoriesPath,
            databasesPath: databases?.path
        ))
    }

    public func resolve() -> LocalACPWorkspaceResolution {
        do {
            guard let stored = try load() else {
                return try resolveDefaultWorkspace()
            }
            let home = homeDirectory
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let root = home.appending(
                path: LocalACPWorkspaceProvisioner.rootDirectoryName,
                directoryHint: .isDirectory
            )
            let externalRepositories = stored.repositoriesPath.map {
                URL(
                    fileURLWithPath: $0,
                    isDirectory: true
                )
            }
            let externalDatabases = stored.databasesPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let repositories = try LocalACPWorkspaceProvisioner.ensureWorkspace(
                at: root,
                repositoriesURL: externalRepositories,
                databasesURL: externalDatabases
            )
            let databases = externalDatabases?.resolvingSymlinksInPath()
                ?? root.appending(path: LocalACPWorkspaceProvisioner.databasesDirectoryName)
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .ready,
                    detail: "Direct chats share \(root.path).",
                    rootPath: root.path,
                    repositoriesPath: repositories.path,
                    databasesPath: databases.path,
                    usesExternalRepositories: externalRepositories != nil,
                    usesExternalDatabases: externalDatabases != nil
                ),
                launchConfiguration: LocalACPWorkspaceLaunchConfiguration(
                    rootURL: root,
                    repositoriesURL: repositories,
                    databasesURL: databases
                )
            )
        } catch {
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .invalidConfiguration,
                    detail: error.localizedDescription,
                    rootPath: nil,
                    repositoriesPath: nil,
                    databasesPath: nil,
                    usesExternalRepositories: false
                ),
                launchConfiguration: nil
            )
        }
    }

    private func resolveDefaultWorkspace() throws -> LocalACPWorkspaceResolution {
        let home = homeDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = home.appending(
            path: LocalACPWorkspaceProvisioner.rootDirectoryName,
            directoryHint: .isDirectory
        )
        let repositories = try LocalACPWorkspaceProvisioner.ensureWorkspace(
            at: root,
            repositoriesURL: nil,
            databasesURL: nil
        )
        let databases = root.appending(
            path: LocalACPWorkspaceProvisioner.databasesDirectoryName,
            directoryHint: .isDirectory
        )
        return LocalACPWorkspaceResolution(
            availability: LocalACPWorkspaceAvailability(
                state: .ready,
                detail: "Direct chats share \(root.path).",
                rootPath: root.path,
                repositoriesPath: repositories.path,
                databasesPath: databases.path,
                usesExternalRepositories: false,
                usesExternalDatabases: false
            ),
            launchConfiguration: LocalACPWorkspaceLaunchConfiguration(
                rootURL: root,
                repositoriesURL: repositories,
                databasesURL: databases
            )
        )
    }

    private func load() throws -> StoredConfiguration? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try JSONDecoder().decode(StoredConfiguration.self, from: data)
    }

    private func save(_ configuration: StoredConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: storageKey)
    }
}

private enum SharedWorkspaceInitializer {
    static func run(at root: URL) throws {
        let fileManager = FileManager.default
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let candidates = [
            Bundle.main.resourceURL?.appending(
                path: "harnesses/initialize-workspace.sh"
            ),
            currentDirectory.appending(path: "harnesses/initialize-workspace.sh"),
            currentDirectory.appending(path: "../harnesses/initialize-workspace.sh"),
        ].compactMap { $0 }
        guard let script = candidates.first(where: {
            fileManager.isReadableFile(atPath: $0.path)
        }) else {
            throw LocalACPWorkspaceError.initializerUnavailable
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, root.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw LocalACPWorkspaceError.initializerFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalACPWorkspaceError.initializerFailed(
                detail.isEmpty ? "exit status \(process.terminationStatus)" : detail
            )
        }
    }
}

public enum LocalACPWorkspaceError: LocalizedError, Equatable, Sendable {
    case workspaceRootIsSymbolicLink
    case selectHomeDirectory
    case repositoriesDirectoryUnavailable
    case repositoriesDirectoryContainsWorkspace
    case defaultRepositoriesNotEmpty
    case databasesDirectoryUnavailable
    case databasesDirectoryContainsWorkspace
    case defaultDatabasesNotEmpty
    case initializerUnavailable
    case initializerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .workspaceRootIsSymbolicLink:
            "The .woven-matter workspace cannot be a symbolic link."
        case .selectHomeDirectory:
            "Woven Matter can create its direct workspace only in the current macOS home directory."
        case .repositoriesDirectoryUnavailable:
            "The selected repositories folder is not an accessible directory."
        case .repositoriesDirectoryContainsWorkspace:
            "Choose a repositories folder outside ~/.woven-matter and its parent directories."
        case .defaultRepositoriesNotEmpty:
            "The default REPOS folder already contains files. Move them before pointing REPOS elsewhere."
        case .databasesDirectoryUnavailable:
            "The selected databases folder is not an accessible directory."
        case .databasesDirectoryContainsWorkspace:
            "Choose a databases folder outside ~/.woven-matter and its parent directories."
        case .defaultDatabasesNotEmpty:
            "The default Databases folder already contains files. Move them before pointing Databases elsewhere."
        case .initializerUnavailable:
            "The shared Woven Matter workspace initializer is unavailable."
        case .initializerFailed(let detail):
            "The shared Woven Matter workspace initializer failed: \(detail)"
        }
    }
}

private extension FileManager {
    func destinationOfSymbolicLinkIfPresent(at url: URL) -> String? {
        try? destinationOfSymbolicLink(atPath: url.path)
    }
}
