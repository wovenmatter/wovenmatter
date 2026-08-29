import Darwin
import Foundation
import WovenMatterCore

public struct LocalAgentDatabase: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let preference: AgentDatabasePreference
    public let url: URL
    public let isExternal: Bool

    public init(
        id: String,
        name: String,
        preference: AgentDatabasePreference,
        url: URL,
        isExternal: Bool
    ) {
        self.id = id
        self.name = name
        self.preference = preference
        self.url = url
        self.isExternal = isExternal
    }
}

public enum AgentDatabaseCatalogError: LocalizedError, Equatable, Sendable {
    case invalidName
    case rootUnavailable
    case databaseAlreadyExists
    case databaseUnavailable
    case externalDirectoryUnavailable
    case externalDirectoryContainsRoot
    case unsafeRelativePath
    case dataFileTooLarge
    case unsupportedManifest

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Use a database name up to 128 characters without slashes or a leading period."
        case .rootUnavailable:
            "The databases folder is unavailable."
        case .databaseAlreadyExists:
            "A database with that name already exists."
        case .databaseUnavailable:
            "The selected database is unavailable."
        case .externalDirectoryUnavailable:
            "The selected external database folder is unavailable."
        case .externalDirectoryContainsRoot:
            "The external database folder cannot contain the Woven Matter databases folder."
        case .unsafeRelativePath:
            "The linked data path must stay inside its database folder."
        case .dataFileTooLarge:
            "The linked data file is too large to render safely."
        case .unsupportedManifest:
            "The database metadata uses an unsupported schema."
        }
    }
}

public enum AgentDatabaseCatalog {
    public static let metadataDirectoryName = ".wovenmatter"
    public static let manifestFileName = "database.json"
    public static let maximumDatabaseCount = 256
    public static let maximumManifestBytes = 16 * 1_024
    public static let maximumSQLiteSnapshotBytes = 256 * 1_024 * 1_024

    public static func list(at rootURL: URL) throws -> [LocalAgentDatabase] {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentDatabaseCatalogError.rootUnavailable
        }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try children
            .filter { isValidName($0.lastPathComponent) }
            .compactMap { child -> LocalAgentDatabase? in
                let values = try child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                let isExternal = values.isSymbolicLink == true
                let resolved = child.resolvingSymlinksInPath()
                var resolvedIsDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: resolved.path,
                    isDirectory: &resolvedIsDirectory
                ), resolvedIsDirectory.boolValue else { return nil }
                return LocalAgentDatabase(
                    id: child.lastPathComponent,
                    name: child.lastPathComponent,
                    preference: try preference(at: resolved),
                    url: resolved,
                    isExternal: isExternal
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(maximumDatabaseCount)
            .map { $0 }
    }

    @discardableResult
    public static func create(
        named rawName: String,
        preference: AgentDatabasePreference,
        in rootURL: URL
    ) throws -> LocalAgentDatabase {
        let name = normalizedName(rawName)
        guard isValidName(name) else { throw AgentDatabaseCatalogError.invalidName }
        let root = try ensureRoot(rootURL)
        let databaseURL = root.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw AgentDatabaseCatalogError.databaseAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: databaseURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try writePreference(preference, at: databaseURL)
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            throw error
        }
        return LocalAgentDatabase(
            id: name,
            name: name,
            preference: preference,
            url: databaseURL,
            isExternal: false
        )
    }

    @discardableResult
    public static func registerExternal(
        _ externalURL: URL,
        named rawName: String? = nil,
        in rootURL: URL
    ) throws -> LocalAgentDatabase {
        let fileManager = FileManager.default
        let root = try ensureRoot(rootURL)
        let target = externalURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentDatabaseCatalogError.externalDirectoryUnavailable
        }
        if root == target || root.path.hasPrefix(target.path + "/") {
            throw AgentDatabaseCatalogError.externalDirectoryContainsRoot
        }
        let name = normalizedName(rawName ?? target.lastPathComponent)
        guard isValidName(name) else { throw AgentDatabaseCatalogError.invalidName }
        let aliasURL = root.appending(path: name, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: aliasURL.path),
              fileManager.destinationOfSymbolicLinkIfPresent(at: aliasURL) == nil else {
            throw AgentDatabaseCatalogError.databaseAlreadyExists
        }
        try fileManager.createSymbolicLink(at: aliasURL, withDestinationURL: target)
        return LocalAgentDatabase(
            id: name,
            name: name,
            preference: try preference(at: target),
            url: target,
            isExternal: true
        )
    }

    public static func setPreference(
        _ preference: AgentDatabasePreference,
        for databaseURL: URL
    ) throws {
        var isDirectory: ObjCBool = false
        let target = databaseURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AgentDatabaseCatalogError.databaseUnavailable
        }
        try writePreference(preference, at: target)
    }

    public static func readDataFile(
        relativePath rawPath: String,
        in databaseURL: URL,
        maximumBytes: Int
    ) throws -> Data {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard maximumBytes >= 0,
              !path.isEmpty, path.utf8.count <= 4_096,
              !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              components.count <= 64,
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                      && !component.hasPrefix(".")
                      && component.count <= 128 && component.utf8.count <= 255
              }) else {
            throw AgentDatabaseCatalogError.unsafeRelativePath
        }

        guard let resolvedRoot = realpath(databaseURL.path, nil) else {
            throw AgentDatabaseCatalogError.databaseUnavailable
        }
        defer { free(resolvedRoot) }
        let resolvedRootPath = String(cString: resolvedRoot)
        let rootComponents = URL(
            fileURLWithPath: resolvedRootPath,
            isDirectory: true
        ).pathComponents
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
        let rootDescriptor = open("/", directoryFlags)
        guard rootDescriptor >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
        var directories = [rootDescriptor]
        defer { for descriptor in directories.reversed() { close(descriptor) } }
        var parent = rootDescriptor
        for component in rootComponents where component != "/" {
            let child = openat(parent, component, directoryFlags)
            guard child >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            directories.append(child)
            parent = child
        }
        for component in components.dropLast() {
            let child = openat(parent, String(component), directoryFlags)
            guard child >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            directories.append(child)
            parent = child
        }
        guard let final = components.last else {
            throw AgentDatabaseCatalogError.unsafeRelativePath
        }
        let descriptor = openat(
            parent,
            String(final),
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw AgentDatabaseCatalogError.databaseUnavailable
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw AgentDatabaseCatalogError.dataFileTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentDatabaseCatalogError.databaseUnavailable
            }
            guard data.count <= maximumBytes - count else {
                throw AgentDatabaseCatalogError.dataFileTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    public static func withConfinedSQLiteFile<Result>(
        relativePath rawPath: String,
        in databaseURL: URL,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              components.count <= 64,
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                      && !component.hasPrefix(".")
                      && component.count <= 128 && component.utf8.count <= 255
              }), let fileName = components.last else {
            throw AgentDatabaseCatalogError.unsafeRelativePath
        }
        guard let resolvedRoot = realpath(databaseURL.path, nil) else {
            throw AgentDatabaseCatalogError.databaseUnavailable
        }
        defer { free(resolvedRoot) }
        let resolvedRootPath = String(cString: resolvedRoot)
        let rootComponents = URL(
            fileURLWithPath: resolvedRootPath,
            isDirectory: true
        ).pathComponents
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
        let rootDescriptor = open("/", directoryFlags)
        guard rootDescriptor >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
        var directories = [rootDescriptor]
        defer { for descriptor in directories.reversed() { close(descriptor) } }
        var parent = rootDescriptor
        for component in rootComponents where component != "/" {
            let child = openat(parent, component, directoryFlags)
            guard child >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            directories.append(child)
            parent = child
        }
        for component in components.dropLast() {
            let child = openat(parent, String(component), directoryFlags)
            guard child >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            directories.append(child)
            parent = child
        }

        func copy(
            _ source: Int32,
            to destinationURL: URL,
            totalBytes: inout Int
        ) throws {
            let destination = open(
                destinationURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
            guard destination >= 0 else {
                throw AgentDatabaseCatalogError.databaseUnavailable
            }
            defer { close(destination) }
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    pread(source, bytes.baseAddress, bytes.count, offset)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentDatabaseCatalogError.databaseUnavailable
                }
                guard totalBytes <= maximumSQLiteSnapshotBytes - count else {
                    throw AgentDatabaseCatalogError.dataFileTooLarge
                }
                totalBytes += count
                var written = 0
                while written < count {
                    let result = buffer.withUnsafeBytes { bytes in
                        write(
                            destination,
                            bytes.baseAddress?.advanced(by: written),
                            count - written
                        )
                    }
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw AgentDatabaseCatalogError.databaseUnavailable
                    }
                    written += result
                }
                offset += off_t(count)
            }
        }

        func unchanged(_ before: stat, _ after: stat) -> Bool {
            before.st_dev == after.st_dev
                && before.st_ino == after.st_ino
                && before.st_size == after.st_size
                && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        }

        func header(of descriptor: Int32) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 8)
            let count = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            return Array(bytes.prefix(count))
        }

        for _ in 0..<3 {
            let source = openat(
                parent, String(fileName), O_RDONLY | O_NOFOLLOW | O_NONBLOCK
            )
            guard source >= 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            defer { close(source) }
            var mainBefore = stat()
            guard fstat(source, &mainBefore) == 0,
                  (mainBefore.st_mode & S_IFMT) == S_IFREG,
                  mainBefore.st_size >= 0 else {
                throw AgentDatabaseCatalogError.databaseUnavailable
            }
            guard mainBefore.st_size <= off_t(maximumSQLiteSnapshotBytes) else {
                throw AgentDatabaseCatalogError.dataFileTooLarge
            }
            let wal = openat(
                parent, String(fileName) + "-wal", O_RDONLY | O_NOFOLLOW | O_NONBLOCK
            )
            if wal < 0 && errno != ENOENT {
                throw AgentDatabaseCatalogError.databaseUnavailable
            }
            defer { if wal >= 0 { close(wal) } }
            let journal = openat(
                parent, String(fileName) + "-journal", O_RDONLY | O_NOFOLLOW | O_NONBLOCK
            )
            if journal < 0 && errno != ENOENT {
                throw AgentDatabaseCatalogError.databaseUnavailable
            }
            defer { if journal >= 0 { close(journal) } }
            var journalBefore = stat()
            var journalHeaderBefore: [UInt8] = []
            if journal >= 0 {
                guard fstat(journal, &journalBefore) == 0,
                      (journalBefore.st_mode & S_IFMT) == S_IFREG,
                      journalBefore.st_size >= 0 else {
                    throw AgentDatabaseCatalogError.databaseUnavailable
                }
                journalHeaderBefore = try header(of: journal)
                if journalBefore.st_size > 512,
                   journalHeaderBefore.contains(where: { $0 != 0 }) {
                    continue
                }
            }
            var walBefore = stat()
            if wal >= 0 {
                guard fstat(wal, &walBefore) == 0,
                      (walBefore.st_mode & S_IFMT) == S_IFREG,
                      walBefore.st_size >= 0 else {
                    throw AgentDatabaseCatalogError.databaseUnavailable
                }
                guard walBefore.st_size <= off_t(maximumSQLiteSnapshotBytes)
                        - mainBefore.st_size else {
                    throw AgentDatabaseCatalogError.dataFileTooLarge
                }
            }

            let snapshot = FileManager.default.temporaryDirectory.appending(
                path: "wovenmatter-sqlite-snapshot-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: snapshot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: snapshot) }
            let snapshotMain = snapshot.appending(path: "database.sqlite")
            var copiedBytes = 0
            try copy(source, to: snapshotMain, totalBytes: &copiedBytes)
            if wal >= 0 {
                try copy(
                    wal,
                    to: snapshot.appending(path: "database.sqlite-wal"),
                    totalBytes: &copiedBytes
                )
            }
            var mainAfter = stat()
            var walAfter = stat()
            var journalAfter = stat()
            let mainStable = fstat(source, &mainAfter) == 0
                && unchanged(mainBefore, mainAfter)
            var walStable = wal < 0 || (
                fstat(wal, &walAfter) == 0 && unchanged(walBefore, walAfter)
            )
            if wal < 0 {
                let appeared = openat(
                    parent, String(fileName) + "-wal", O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                )
                if appeared >= 0 {
                    close(appeared)
                    walStable = false
                } else if errno != ENOENT {
                    throw AgentDatabaseCatalogError.databaseUnavailable
                }
            }
            var journalStable: Bool
            if journal >= 0 {
                let journalHeaderAfter = try header(of: journal)
                journalStable = fstat(journal, &journalAfter) == 0
                    && unchanged(journalBefore, journalAfter)
                    && journalHeaderAfter == journalHeaderBefore
            } else {
                let appeared = openat(
                    parent, String(fileName) + "-journal",
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                )
                if appeared >= 0 {
                    close(appeared)
                    journalStable = false
                } else if errno == ENOENT {
                    journalStable = true
                } else {
                    throw AgentDatabaseCatalogError.databaseUnavailable
                }
            }
            if mainStable && walStable && journalStable {
                return try body(snapshotMain)
            }
        }
        throw AgentDatabaseCatalogError.databaseUnavailable
    }

    private static func ensureRoot(_ rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AgentDatabaseCatalogError.rootUnavailable
        }
        return root
    }

    private static func preference(at databaseURL: URL) throws -> AgentDatabasePreference {
        let databaseDescriptor = open(
            databaseURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard databaseDescriptor >= 0 else { return .none }
        defer { close(databaseDescriptor) }
        let metadataDescriptor = openat(
            databaseDescriptor,
            metadataDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard metadataDescriptor >= 0 else { return .none }
        defer { close(metadataDescriptor) }
        let manifestDescriptor = openat(
            metadataDescriptor,
            manifestFileName,
            O_RDONLY | O_NOFOLLOW
        )
        guard manifestDescriptor >= 0 else { return .none }
        defer { close(manifestDescriptor) }
        var status = stat()
        guard fstat(manifestDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumManifestBytes),
              let data = readData(
                from: manifestDescriptor,
                maximumBytes: maximumManifestBytes
              ),
              let manifest = try? JSONDecoder().decode(AgentDatabaseManifest.self, from: data)
        else { return .none }
        return manifest.isSupported ? manifest.preference : .none
    }

    private static func writePreference(
        _ preference: AgentDatabasePreference,
        at databaseURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(AgentDatabaseManifest(preference: preference))
        data.append(0x0A)

        let databaseDescriptor = open(
            databaseURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard databaseDescriptor >= 0 else {
            throw AgentDatabaseCatalogError.databaseUnavailable
        }
        defer { close(databaseDescriptor) }

        if mkdirat(databaseDescriptor, metadataDirectoryName, 0o700) != 0,
           errno != EEXIST {
            throw AgentDatabaseCatalogError.unsupportedManifest
        }
        let metadataDescriptor = openat(
            databaseDescriptor,
            metadataDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard metadataDescriptor >= 0 else {
            throw AgentDatabaseCatalogError.unsupportedManifest
        }
        defer { close(metadataDescriptor) }

        let temporaryName = ".database-\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = openat(
            metadataDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard temporaryDescriptor >= 0 else {
            throw AgentDatabaseCatalogError.unsupportedManifest
        }
        var shouldRemoveTemporary = true
        defer {
            close(temporaryDescriptor)
            if shouldRemoveTemporary {
                unlinkat(metadataDescriptor, temporaryName, 0)
            }
        }
        guard writeAll(data, to: temporaryDescriptor), fsync(temporaryDescriptor) == 0,
              renameat(
                metadataDescriptor,
                temporaryName,
                metadataDescriptor,
                manifestFileName
              ) == 0 else {
            throw AgentDatabaseCatalogError.unsupportedManifest
        }
        shouldRemoveTemporary = false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func readData(from descriptor: Int32, maximumBytes: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: total),
                    bytes.count - total
                )
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += count
        }
        guard total <= maximumBytes else { return nil }
        return Data(buffer.prefix(total))
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains(":")
            && name.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
            && name.count <= 128
            && name.utf8.count <= 255
    }
}

private extension FileManager {
    func destinationOfSymbolicLinkIfPresent(at url: URL) -> String? {
        try? destinationOfSymbolicLink(atPath: url.path)
    }
}
