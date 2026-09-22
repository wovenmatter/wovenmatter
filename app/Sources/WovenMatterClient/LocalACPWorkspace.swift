import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

public enum LocalACPWorkspaceFolder: Sendable {
    case repositories
    case databases

    public var directoryName: String {
        switch self {
        case .repositories: "Repos"
        case .databases: "Databases"
        }
    }

    var nonemptyError: LocalACPWorkspaceError {
        self == .repositories ? .defaultRepositoriesNotEmpty : .defaultDatabasesNotEmpty
    }

    var unavailableError: LocalACPWorkspaceError {
        self == .repositories ? .repositoriesDirectoryUnavailable : .databasesDirectoryUnavailable
    }

    var containsWorkspaceError: LocalACPWorkspaceError {
        self == .repositories ? .repositoriesDirectoryContainsWorkspace : .databasesDirectoryContainsWorkspace
    }
}

public struct LocalACPWorkspaceFolderChangeResult: Sendable {
    public let backupURL: URL?
    public let skippedItemNames: [String]
}

public enum LocalACPWorkspaceProvisioner {
    public static let rootDirectoryName = ".woven-matter"
    public static let repositoriesDirectoryName = "Repos"
    public static let databasesDirectoryName = "Databases"
    public static let knowledgeDirectories = [
        "GUIDES", "PLANS", "RESEARCH", "WORK_LOGS", "OUTBOX", ".scratch",
    ]

    /// Finds the legacy spelling before the initializer has migrated it.
    public static func directoryURL(for folder: LocalACPWorkspaceFolder, at root: URL) -> URL {
        let preferred = root.appending(path: folder.directoryName, directoryHint: .isDirectory)
        if folder == .repositories, !itemExists(preferred) {
            let legacy = root.appending(path: "REPOS", directoryHint: .isDirectory)
            if itemExists(legacy) { return legacy }
        }
        return preferred
    }

    /// Startup preserves existing links. Only configureDirectory may reset one.
    public static func ensureWorkspace(
        at rootURL: URL,
        repositoriesURL: URL?,
        databasesURL: URL? = nil
    ) throws -> URL {
        let root = try prepareWorkspace(at: rootURL)
        _ = try reconcileDirectory(
            .databases, at: root, externalURL: databasesURL,
            explicitlySelected: false, backUpExistingContents: false
        )
        return try reconcileDirectory(
            .repositories, at: root, externalURL: repositoriesURL,
            explicitlySelected: false, backUpExistingContents: false
        ).directory
    }

    /// Explicit user changes affect only the selected folder, so an unavailable
    /// second folder cannot prevent recovery. Returns any preserved default folder.
    @discardableResult
    public static func configureDirectory(
        _ folder: LocalACPWorkspaceFolder,
        at rootURL: URL,
        externalURL: URL?,
        backUpExistingContents: Bool = false,
        copyExistingContents: Bool = false
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        let root = try prepareWorkspace(at: rootURL)
        let result = try reconcileDirectory(
            folder, at: root, externalURL: externalURL,
            explicitlySelected: true, backUpExistingContents: backUpExistingContents,
            copyExistingContents: copyExistingContents
        )
        return LocalACPWorkspaceFolderChangeResult(backupURL: result.backup, skippedItemNames: result.skippedItems)
    }

    private static func prepareWorkspace(at rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        if isSymbolicLink(root) { throw LocalACPWorkspaceError.workspaceRootIsSymbolicLink }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try setOwnerOnlyDirectoryPermissions(root)
        try SharedWorkspaceInitializer.run(at: root)
        return root
    }

    private static func reconcileDirectory(
        _ folder: LocalACPWorkspaceFolder,
        at root: URL,
        externalURL: URL?,
        explicitlySelected: Bool,
        backUpExistingContents: Bool,
        copyExistingContents: Bool = false
    ) throws -> (directory: URL, backup: URL?, skippedItems: [String]) {
        let fileManager = FileManager.default
        let link = directoryURL(for: folder, at: root)
        let previousDestination = fileManager.destinationOfSymbolicLinkIfPresent(at: link)
        guard let externalURL else {
            if let previousDestination {
                if !explicitlySelected {
                    return (try validateTarget(link, folder: folder, workspaceRoot: root), nil, [])
                }
                try fileManager.removeItem(at: link)
                do {
                    try fileManager.createDirectory(at: link, withIntermediateDirectories: false)
                } catch {
                    try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: previousDestination)
                    throw error
                }
            } else {
                try fileManager.createDirectory(at: link, withIntermediateDirectories: true)
            }
            try setOwnerOnlyDirectoryPermissions(link)
            return (link, nil, [])
        }

        // Selecting the populated default itself is valid, and must never make
        // a self-referencing link or require the user to empty it.
        if previousDestination == nil,
           externalURL.standardizedFileURL.resolvingSymlinksInPath() == link.resolvingSymlinksInPath() {
            return (link, nil, [])
        }
        let target = try validateTarget(externalURL, folder: folder, workspaceRoot: root)
        if previousDestination != nil, link.resolvingSymlinksInPath() == target {
            return (target, nil, [])
        }

        var backup: URL?
        var skippedItems: [String] = []
        if let previousDestination {
            try fileManager.removeItem(at: link)
            do {
                try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: previousDestination)
                throw error
            }
        } else {
            if itemExists(link) {
                let contents = try fileManager.contentsOfDirectory(atPath: link.path)
                guard contents.isEmpty || backUpExistingContents else { throw folder.nonemptyError }
                if copyExistingContents {
                    for item in try fileManager.contentsOfDirectory(at: link, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        let destination = target.appending(path: item.lastPathComponent)
                        if itemExists(destination) {
                            skippedItems.append(item.lastPathComponent)
                            continue
                        }
                        // copyItem refuses an existing destination. Keep the full
                        // source backup even after successful copies.
                        do {
                            try fileManager.copyItem(at: item, to: destination)
                        } catch {
                            throw LocalACPWorkspaceError.copyFailed(error.localizedDescription)
                        }
                    }
                }
                // Move the whole folder before linking; never recursively delete
                // a directory that an agent could still be writing into.
                let saved = root.appending(path: "\(folder.directoryName) Backup \(UUID().uuidString)")
                try fileManager.moveItem(at: link, to: saved)
                backup = saved
            }
            do {
                try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                if let backup { try fileManager.moveItem(at: backup, to: link) }
                throw error
            }
            // rmdir removes only an empty directory, including under concurrent writes.
            if let saved = backup, saved.path.withCString({ rmdir($0) }) == 0 { backup = nil }
        }
        return (target, backup, skippedItems)
    }

    private static func validateTarget(
        _ url: URL, folder: LocalACPWorkspaceFolder, workspaceRoot: URL
    ) throws -> URL {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw folder.unavailableError }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let current = directoryURL(for: folder, at: root)
        if root == target || root.path.hasPrefix(target.path + "/")
            || (!isSymbolicLink(current) && target.path.hasPrefix(current.resolvingSymlinksInPath().path + "/")) {
            throw folder.containsWorkspaceError
        }
        return target
    }

    static func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        FileManager.default.destinationOfSymbolicLinkIfPresent(at: url) != nil
    }

    private static func setOwnerOnlyDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public actor LocalACPWorkspaceConfigurationStore {
    private struct StoredConfiguration: Codable, Sendable {
        let repositoriesPath: String?
        let databasesPath: String?
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let homeDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaultsSuiteName: String? = nil,
        storageKey: String = "wovenmatter.local-agent-workspace.folders"
    ) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.storageKey = storageKey
        self.homeDirectory = homeDirectory
    }

    private var root: URL {
        homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appending(path: LocalACPWorkspaceProvisioner.rootDirectoryName, directoryHint: .isDirectory)
    }

    public func setUpWorkspace(in homeDirectory: URL) throws {
        guard homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
                == self.homeDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw LocalACPWorkspaceError.selectHomeDirectory
        }
        let folders = currentFolders()
        _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(
            at: root, repositoriesURL: folders.repositories, databasesURL: folders.databases
        )
    }

    @discardableResult
    public func configureRepositories(_ repositoriesURL: URL?, backUpExistingContents: Bool = false, copyExistingContents: Bool = false) throws -> LocalACPWorkspaceFolderChangeResult {
        try configure(.repositories, externalURL: repositoriesURL, backUpExistingContents: backUpExistingContents, copyExistingContents: copyExistingContents)
    }

    @discardableResult
    public func configureDatabases(_ databasesURL: URL?, backUpExistingContents: Bool = false, copyExistingContents: Bool = false) throws -> LocalACPWorkspaceFolderChangeResult {
        try configure(.databases, externalURL: databasesURL, backUpExistingContents: backUpExistingContents, copyExistingContents: copyExistingContents)
    }

    private func configure(
        _ folder: LocalACPWorkspaceFolder, externalURL: URL?, backUpExistingContents: Bool, copyExistingContents: Bool
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        let backup = try LocalACPWorkspaceProvisioner.configureDirectory(
            folder, at: root, externalURL: externalURL, backUpExistingContents: backUpExistingContents, copyExistingContents: copyExistingContents
        )
        // Preferences remain a migration fallback only. The shared filesystem is
        // authoritative, including changes made by another app build or in Finder.
        let folders = currentFolders()
        let stored = StoredConfiguration(
            repositoriesPath: folders.repositories?.path,
            databasesPath: folders.databases?.path
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: storageKey)
        return backup
    }

    private func currentFolders() -> (repositories: URL?, databases: URL?) {
        let stored = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(StoredConfiguration.self, from: $0)
        }
        func existingTarget(_ folder: LocalACPWorkspaceFolder, fallback: String?) -> URL? {
            let path = LocalACPWorkspaceProvisioner.directoryURL(for: folder, at: root)
            if let destination = FileManager.default.destinationOfSymbolicLinkIfPresent(at: path) {
                return URL(fileURLWithPath: destination, relativeTo: path.deletingLastPathComponent())
                    .standardizedFileURL.resolvingSymlinksInPath()
            }
            if LocalACPWorkspaceProvisioner.itemExists(path) { return nil }
            return fallback.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return (
            existingTarget(.repositories, fallback: stored?.repositoriesPath),
            existingTarget(.databases, fallback: stored?.databasesPath)
        )
    }

    public func resolve() -> LocalACPWorkspaceResolution {
        let folders = currentFolders()
        let repositories = folders.repositories
            ?? LocalACPWorkspaceProvisioner.directoryURL(for: .repositories, at: root)
        let databases = folders.databases
            ?? LocalACPWorkspaceProvisioner.directoryURL(for: .databases, at: root)
        do {
            let resolvedRepositories = try LocalACPWorkspaceProvisioner.ensureWorkspace(
                at: root, repositoriesURL: folders.repositories, databasesURL: folders.databases
            )
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .ready, detail: "Direct chats share \(root.path).",
                    rootPath: root.path, repositoriesPath: resolvedRepositories.path,
                    databasesPath: databases.path,
                    usesExternalRepositories: folders.repositories != nil,
                    usesExternalDatabases: folders.databases != nil
                ),
                launchConfiguration: LocalACPWorkspaceLaunchConfiguration(
                    rootURL: root, repositoriesURL: resolvedRepositories, databasesURL: databases
                )
            )
        } catch {
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .invalidConfiguration, detail: error.localizedDescription,
                    rootPath: root.path, repositoriesPath: repositories.path,
                    databasesPath: databases.path,
                    usesExternalRepositories: folders.repositories != nil,
                    usesExternalDatabases: folders.databases != nil
                ),
                launchConfiguration: nil
            )
        }
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
    case copyFailed(String)
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
            "The repositories folder cannot contain the workspace or be inside the Repos folder it would replace."
        case .defaultRepositoriesNotEmpty:
            "The default Repos folder contains files. Back them up before changing the folder."
        case .databasesDirectoryUnavailable:
            "The selected databases folder is not an accessible directory."
        case .databasesDirectoryContainsWorkspace:
            "The databases folder cannot contain the workspace or be inside the Databases folder it would replace."
        case .defaultDatabasesNotEmpty:
            "The default Databases folder contains files. Back them up before changing the folder."
        case .copyFailed(let detail):
            "Could not finish copying files. Your original folder is still in use and its contents are preserved. Some files may already have been copied to the selected folder. \(detail)"
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
