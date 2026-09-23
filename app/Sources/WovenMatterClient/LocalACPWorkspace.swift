import Foundation
import Darwin

public struct LocalACPWorkspaceAvailability: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
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

public enum LocalACPWorkspaceFolder: Codable, Sendable {
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

public enum LocalACPWorkspaceFolderRecovery: Sendable {
    case requireConfirmation
    case backUp
    case copyAndBackUp
}

public struct LocalACPWorkspaceFolderChangeResult: Codable, Sendable {
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

    /// Existing folders are authoritative; saved destinations only seed missing folders.
    public static func ensureWorkspace(
        at rootURL: URL,
        repositoriesURL: URL?,
        databasesURL: URL? = nil
    ) throws -> URL {
        try prepareLaunchConfiguration(
            at: rootURL, repositoriesURL: repositoriesURL, databasesURL: databasesURL
        ).repositoriesURL
    }

    static func prepareLaunchConfiguration(
        at rootURL: URL, repositoriesURL: URL?, databasesURL: URL?
    ) throws -> LocalACPWorkspaceLaunchConfiguration {
        try withWorkspaceLock(at: rootURL) { root in
            let repositories = try ensureDirectory(.repositories, at: root, fallback: repositoriesURL)
            let databases = try ensureDirectory(.databases, at: root, fallback: databasesURL)
            return LocalACPWorkspaceLaunchConfiguration(
                rootURL: root, repositoriesURL: repositories, databasesURL: databases
            )
        }
    }

    /// Changes only the selected folder, so another unavailable folder cannot block recovery.
    @discardableResult
    public static func configureDirectory(
        _ folder: LocalACPWorkspaceFolder,
        at rootURL: URL,
        externalURL: URL?,
        recovery: LocalACPWorkspaceFolderRecovery = .requireConfirmation
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        try withWorkspaceLock(at: rootURL) { root in
            try replaceDirectory(folder, at: root, externalURL: externalURL, recovery: recovery)
        }
    }

    private static func withWorkspaceLock<T>(at rootURL: URL, perform: (URL) throws -> T) throws -> T {
        let root = rootURL.standardizedFileURL
        if isSymbolicLink(root) { throw LocalACPWorkspaceError.workspaceRootIsSymbolicLink }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try setOwnerOnlyDirectoryPermissions(root)

        // Separate app builds share this lock, including initialization and rollback.
        let descriptor = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        try SharedWorkspaceInitializer.run(at: root)
        return try perform(root)
    }

    private static func ensureDirectory(
        _ folder: LocalACPWorkspaceFolder, at root: URL, fallback: URL?
    ) throws -> URL {
        let path = directoryURL(for: folder, at: root)
        if itemExists(path) {
            return try validateTarget(path, folder: folder, workspaceRoot: root)
        }
        _ = try replaceDirectory(folder, at: root, externalURL: fallback, recovery: .requireConfirmation)
        return path.resolvingSymlinksInPath()
    }

    private static func replaceDirectory(
        _ folder: LocalACPWorkspaceFolder,
        at root: URL,
        externalURL: URL?,
        recovery: LocalACPWorkspaceFolderRecovery
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        let fileManager = FileManager.default
        let link = directoryURL(for: folder, at: root)
        let previousDestination = fileManager.destinationOfSymbolicLinkIfPresent(at: link)
        guard let externalURL else {
            if previousDestination != nil {
                let replacement = root.appending(path: ".wovenmatter-folder-\(UUID().uuidString)")
                try fileManager.createDirectory(at: replacement, withIntermediateDirectories: false)
                defer { try? fileManager.removeItem(at: replacement) }
                try setOwnerOnlyDirectoryPermissions(replacement)
                try exchangeItems(at: link, and: replacement)
            } else {
                try fileManager.createDirectory(at: link, withIntermediateDirectories: true)
            }
            try setOwnerOnlyDirectoryPermissions(link)
            return LocalACPWorkspaceFolderChangeResult(backupURL: nil, skippedItemNames: [])
        }

        let target = try validateTarget(externalURL, folder: folder, workspaceRoot: root)
        // Selecting the default itself is valid even when it already contains files.
        if link.resolvingSymlinksInPath() == target {
            return LocalACPWorkspaceFolderChangeResult(backupURL: nil, skippedItemNames: [])
        }
        if previousDestination != nil {
            let replacement = root.appending(path: ".wovenmatter-folder-\(UUID().uuidString)")
            try fileManager.createSymbolicLink(at: replacement, withDestinationURL: target)
            defer { try? fileManager.removeItem(at: replacement) }
            try exchangeItems(at: link, and: replacement)
            return LocalACPWorkspaceFolderChangeResult(backupURL: nil, skippedItemNames: [])
        }

        var backup: URL?
        var skippedItems: [String] = []
        if itemExists(link) {
            let contents = try fileManager.contentsOfDirectory(at: link, includingPropertiesForKeys: nil)
            guard contents.isEmpty || recovery != .requireConfirmation else { throw folder.nonemptyError }
            if recovery == .copyAndBackUp {
                skippedItems = try copyContents(contents, to: target)
            }
            // Preserve the whole folder, including writes made after the initial listing.
            let saved = root.appending(path: "\(folder.directoryName) Backup \(UUID().uuidString)")
            try fileManager.createSymbolicLink(at: saved, withDestinationURL: target)
            do {
                try exchangeItems(at: link, and: saved)
            } catch {
                try? fileManager.removeItem(at: saved)
                throw error
            }
            backup = saved
        } else {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        }
        // Never recursively delete a folder that an agent could still be writing into.
        if let saved = backup, saved.path.withCString({ rmdir($0) }) == 0 { backup = nil }
        return LocalACPWorkspaceFolderChangeResult(backupURL: backup, skippedItemNames: skippedItems)
    }

    /// Keep the live path and its backup valid across a crash, including when
    /// exchanging a directory and a link. Unsupported filesystems fail unchanged.
    private static func exchangeItems(at first: URL, and second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func copyContents(_ contents: [URL], to target: URL) throws -> [String] {
        let fileManager = FileManager.default
        var skippedItems: [String] = []
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let destination = target.appending(path: item.lastPathComponent)
            if itemExists(destination) {
                skippedItems.append(item.lastPathComponent)
                continue
            }
            // Publish each item only after its complete copy succeeds. A failed copy
            // must not become a partial repository that a later retry skips as existing.
            let staging = target.appending(path: ".wovenmatter-copy-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
                let stagedItem = staging.appending(path: item.lastPathComponent)
                try fileManager.copyItem(at: item, to: stagedItem)
                do {
                    guard renamex_np(stagedItem.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    // A different writer may have created the destination during the copy.
                    guard itemExists(destination) else { throw error }
                    skippedItems.append(item.lastPathComponent)
                }
            } catch {
                throw LocalACPWorkspaceError.copyFailed(error.localizedDescription)
            }
        }
        return skippedItems
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
        if root.pathComponents.starts(with: target.pathComponents)
            || (!isSymbolicLink(current)
                && target != current.resolvingSymlinksInPath()
                && target.pathComponents.starts(with: current.resolvingSymlinksInPath().pathComponents)) {
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
    public func configureRepositories(
        _ repositoriesURL: URL?, recovery: LocalACPWorkspaceFolderRecovery = .requireConfirmation
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        try configure(.repositories, externalURL: repositoriesURL, recovery: recovery)
    }

    @discardableResult
    public func configureDatabases(
        _ databasesURL: URL?, recovery: LocalACPWorkspaceFolderRecovery = .requireConfirmation
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        try configure(.databases, externalURL: databasesURL, recovery: recovery)
    }

    private func configure(
        _ folder: LocalACPWorkspaceFolder, externalURL: URL?, recovery: LocalACPWorkspaceFolderRecovery
    ) throws -> LocalACPWorkspaceFolderChangeResult {
        let result = try LocalACPWorkspaceProvisioner.configureDirectory(
            folder, at: root, externalURL: externalURL, recovery: recovery
        )
        // Preferences remain a migration fallback only. The shared filesystem is
        // authoritative, including changes made by another app build or in Finder.
        let folders = currentFolders()
        let stored = StoredConfiguration(
            repositoriesPath: folders.repositories?.path,
            databasesPath: folders.databases?.path
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: storageKey)
        return result
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
        do {
            let folders = currentFolders()
            let configuration = try LocalACPWorkspaceProvisioner.prepareLaunchConfiguration(
                at: root, repositoriesURL: folders.repositories, databasesURL: folders.databases
            )
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .ready, detail: "Direct chats share \(root.path).",
                    rootPath: root.path, repositoriesPath: configuration.repositoriesURL.path,
                    databasesPath: configuration.databasesURL.path,
                    usesExternalRepositories: configuration.repositoriesURL != directoryURL(.repositories),
                    usesExternalDatabases: configuration.databasesURL != directoryURL(.databases)
                ),
                launchConfiguration: configuration
            )
        } catch {
            let folders = currentFolders()
            return LocalACPWorkspaceResolution(
                availability: LocalACPWorkspaceAvailability(
                    state: .invalidConfiguration, detail: error.localizedDescription,
                    rootPath: root.path,
                    repositoriesPath: (folders.repositories ?? directoryURL(.repositories)).path,
                    databasesPath: (folders.databases ?? directoryURL(.databases)).path,
                    usesExternalRepositories: folders.repositories != nil,
                    usesExternalDatabases: folders.databases != nil
                ),
                launchConfiguration: nil
            )
        }
    }

    private func directoryURL(_ folder: LocalACPWorkspaceFolder) -> URL {
        LocalACPWorkspaceProvisioner.directoryURL(for: folder, at: root)
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
        process.arguments = [script.path, root.path, "--skip-linked-folders"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw LocalACPWorkspaceError.initializerFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
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
