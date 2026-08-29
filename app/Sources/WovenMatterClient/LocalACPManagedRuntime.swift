import CryptoKit
import Foundation
import WovenMatterCore

public enum LocalACPRuntimeInstallComponent: Sendable {
    case cli
    case adapter
}

public struct LocalACPManagedNodeArtifact: Equatable, Sendable {
    public let version: String
    public let platform: String
    public let archiveFileName: String
    public let sha256: String

    public init(
        version: String,
        platform: String,
        archiveFileName: String,
        sha256: String
    ) {
        self.version = version
        self.platform = platform
        self.archiveFileName = archiveFileName
        self.sha256 = sha256
    }

    public var downloadURL: URL {
        URL(
            string: "https://nodejs.org/dist/\(version)/\(archiveFileName)"
        )!
    }

    public static var current: LocalACPManagedNodeArtifact {
        #if arch(arm64)
        LocalACPManagedNodeArtifact(
            version: "v24.18.0",
            platform: "darwin-arm64",
            archiveFileName: "node-v24.18.0-darwin-arm64.tar.gz",
            sha256: "e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
        )
        #elseif arch(x86_64)
        LocalACPManagedNodeArtifact(
            version: "v24.18.0",
            platform: "darwin-x64",
            archiveFileName: "node-v24.18.0-darwin-x64.tar.gz",
            sha256: "dfd0dbd3e721503434df7b7205e719f61b3a3a31b2bcf9729b8b91fea240f080"
        )
        #else
        #error("Woven Matter's managed Node runtime supports macOS arm64 and x86_64.")
        #endif
    }
}

public enum LocalACPManagedRuntimePaths {
    public static var applicationSupportDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appending(
            path: "Woven Matter",
            directoryHint: .isDirectory
        )
    }

    public static var nodeToolsPrefix: URL {
        applicationSupportDirectory.appending(
            path: "Node Tools",
            directoryHint: .isDirectory
        )
    }

    public static var nodeToolsBinDirectory: URL {
        nodeToolsPrefix.appending(path: "bin", directoryHint: .isDirectory)
    }

    public static var nodeRuntimeRoot: URL {
        applicationSupportDirectory
            .appending(path: "Runtimes", directoryHint: .isDirectory)
            .appending(path: "Node", directoryHint: .isDirectory)
    }

    public static func nodeRuntimeDirectory(
        for artifact: LocalACPManagedNodeArtifact
    ) -> URL {
        nodeRuntimeRoot
            .appending(path: artifact.version, directoryHint: .isDirectory)
            .appending(path: artifact.platform, directoryHint: .isDirectory)
    }

    public static func nodeBinDirectory(
        for artifact: LocalACPManagedNodeArtifact = .current
    ) -> URL {
        nodeRuntimeDirectory(for: artifact).appending(
            path: "bin",
            directoryHint: .isDirectory
        )
    }
}

public actor LocalACPManagedNodeRuntime {
    public typealias Downloader = @Sendable (URL) async throws -> Data

    private static let maximumArchiveBytes = 90 * 1_024 * 1_024

    public let rootDirectory: URL
    public let artifact: LocalACPManagedNodeArtifact
    private let downloader: Downloader?

    public init(
        rootDirectory: URL = LocalACPManagedRuntimePaths.nodeRuntimeRoot,
        artifact: LocalACPManagedNodeArtifact = .current,
        downloader: Downloader? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.artifact = artifact
        self.downloader = downloader
    }

    public func ensureInstalled() async throws -> URL {
        let finalDirectory = runtimeDirectory
        if runtimeIsReady(at: finalDirectory) {
            return finalDirectory.appending(path: "bin/npm")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let token = UUID().uuidString
        let archiveURL = rootDirectory.appending(
            path: "\(artifact.archiveFileName).\(token).download"
        )
        let temporaryDirectory = rootDirectory.appending(
            path: "\(artifact.version).\(artifact.platform).\(token).tmp",
            directoryHint: .isDirectory
        )
        defer {
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        if let downloader {
            let data = try await downloader(artifact.downloadURL)
            guard data.count <= Self.maximumArchiveBytes else {
                throw LocalACPManagedNodeError.archiveTooLarge(data.count)
            }
            try data.write(to: archiveURL, options: .atomic)
        } else {
            do {
                _ = try await LocalACPBoundedHTTPSDownloader.download(
                    artifact.downloadURL,
                    to: archiveURL,
                    maximumBytes: Self.maximumArchiveBytes
                )
            } catch let error as LocalACPBoundedDownloadError {
                switch error {
                case .tooLarge(let bytes):
                    throw LocalACPManagedNodeError.archiveTooLarge(bytes)
                case .unsafeURL, .invalidResponse, .transportFailed:
                    throw LocalACPManagedNodeError.downloadFailed
                }
            }
        }
        let actualHash = try Self.sha256Hex(fileAt: archiveURL)
        guard actualHash == artifact.sha256.lowercased() else {
            throw LocalACPManagedNodeError.hashMismatch(
                expected: artifact.sha256,
                actual: actualHash
            )
        }

        try validateArchive(at: archiveURL)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let extraction = try LocalACPProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf",
                archiveURL.path,
                "-C",
                temporaryDirectory.path,
                "--strip-components=1",
            ]
        )
        guard extraction.succeeded else {
            throw LocalACPManagedNodeError.extractionFailed(
                extraction.combinedOutput
            )
        }
        guard runtimeIsReady(at: temporaryDirectory) else {
            throw LocalACPManagedNodeError.runtimeVerificationFailed
        }

        try activate(
            temporaryDirectory: temporaryDirectory,
            finalDirectory: finalDirectory
        )
        guard runtimeIsReady(at: finalDirectory) else {
            throw LocalACPManagedNodeError.runtimeVerificationFailed
        }
        return finalDirectory.appending(path: "bin/npm")
    }

    private var runtimeDirectory: URL {
        rootDirectory
            .appending(path: artifact.version, directoryHint: .isDirectory)
            .appending(path: artifact.platform, directoryHint: .isDirectory)
    }

    private func runtimeIsReady(at directory: URL) -> Bool {
        let node = directory.appending(path: "bin/node")
        let npm = directory.appending(path: "bin/npm")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.isExecutableFile(atPath: npm.path),
              let result = try? LocalACPProcessRunner.run(
                executableURL: node,
                arguments: ["--version"]
              ),
              result.succeeded
        else {
            return false
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == artifact.version
    }

    private func validateArchive(at archiveURL: URL) throws {
        let listing = try LocalACPProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", archiveURL.path]
        )
        guard listing.succeeded else {
            throw LocalACPManagedNodeError.invalidArchive(
                listing.combinedOutput
            )
        }
        for entry in listing.stdout.split(whereSeparator: \.isNewline) {
            let path = String(entry)
            guard !path.hasPrefix("/"),
                  !path.hasPrefix("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains("..")
            else {
                throw LocalACPManagedNodeError.unsafeArchiveEntry(path)
            }
        }
    }

    private func activate(
        temporaryDirectory: URL,
        finalDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: finalDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let oldDirectory = finalDirectory.appendingPathExtension("old")
        if fileManager.fileExists(atPath: oldDirectory.path) {
            try fileManager.removeItem(at: oldDirectory)
        }
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.moveItem(at: finalDirectory, to: oldDirectory)
        }
        do {
            try fileManager.moveItem(
                at: temporaryDirectory,
                to: finalDirectory
            )
            if fileManager.fileExists(atPath: oldDirectory.path) {
                try fileManager.removeItem(at: oldDirectory)
            }
        } catch {
            if fileManager.fileExists(atPath: oldDirectory.path),
               !fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(
                    at: oldDirectory,
                    to: finalDirectory
                )
            }
            throw error
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            let data = try file.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalACPBoundedDownloadError: Error, Equatable {
    case unsafeURL
    case invalidResponse
    case tooLarge(Int)
    case transportFailed
}

enum LocalACPBoundedHTTPSDownloader {
    static func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int
    ) async throws -> Int {
        guard isSafeHTTPS(url), maximumBytes > 0 else {
            throw LocalACPBoundedDownloadError.unsafeURL
        }
        let delegate = LocalACPBoundedDownloadDelegate(
            destination: destination,
            maximumBytes: maximumBytes
        )
        return try await delegate.download(url)
    }

    static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }

    static func validate(
        byteCount: Int64,
        maximumBytes: Int
    ) throws {
        guard byteCount <= Int64(maximumBytes) else {
            throw LocalACPBoundedDownloadError.tooLarge(Int(byteCount))
        }
    }
}

private final class LocalACPBoundedDownloadDelegate:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let destination: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, any Error>?
    private var session: URLSession?
    private var completed = false

    init(destination: URL, maximumBytes: Int) {
        self.destination = destination
        self.maximumBytes = maximumBytes
    }

    func download(_ url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            request.url.map(LocalACPBoundedHTTPSDownloader.isSafeHTTPS) == true
                ? request
                : nil
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        do {
            try validate(response: downloadTask.response)
            try LocalACPBoundedHTTPSDownloader.validate(
                byteCount: totalBytesWritten,
                maximumBytes: maximumBytes
            )
        } catch {
            downloadTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try validate(response: downloadTask.response)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: location.path
            )
            let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard bytes > 0, bytes <= maximumBytes else {
                throw LocalACPBoundedDownloadError.tooLarge(bytes)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(bytes))
        } catch let error as LocalACPBoundedDownloadError {
            finish(.failure(error))
        } catch {
            finish(.failure(LocalACPBoundedDownloadError.transportFailed))
        }
    }

    private func validate(response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response?.url.map(LocalACPBoundedHTTPSDownloader.isSafeHTTPS) == true
        else { throw LocalACPBoundedDownloadError.invalidResponse }
        if response?.expectedContentLength ?? -1 > Int64(maximumBytes) {
            throw LocalACPBoundedDownloadError.tooLarge(
                Int(response?.expectedContentLength ?? 0)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard error != nil else { return }
        finish(.failure(LocalACPBoundedDownloadError.transportFailed))
    }

    private func finish(_ result: Result<Int, any Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

public struct LocalACPInstallerPreview: Equatable, Sendable {
    public let runtimeKind: AgentRuntimeKind
    public let source: URL
    public let sha256: String?
    public let bytes: Int?
    public let packageSpec: String?
    public let verification: String

    public init(
        runtimeKind: AgentRuntimeKind,
        source: URL,
        sha256: String?,
        bytes: Int?,
        packageSpec: String?,
        verification: String
    ) {
        self.runtimeKind = runtimeKind
        self.source = source
        self.sha256 = sha256
        self.bytes = bytes
        self.packageSpec = packageSpec
        self.verification = verification
    }
}

public actor LocalACPRuntimeInstaller {
    public typealias InstallerFetcher = @Sendable (
        URL,
        URL,
        Int
    ) async throws -> Int

    private static let maximumInstallerBytes = 5 * 1_024 * 1_024

    public let installPrefix: URL
    private let managedNodeRuntime: LocalACPManagedNodeRuntime
    private let npmExecutableURL: URL?
    private let installerFetcher: InstallerFetcher?
    private let executableResolver: (@Sendable (String) -> URL?)?

    public init(
        installPrefix: URL = LocalACPManagedRuntimePaths.nodeToolsPrefix,
        managedNodeRuntime: LocalACPManagedNodeRuntime = LocalACPManagedNodeRuntime(),
        npmExecutableURL: URL? = nil,
        installerFetcher: InstallerFetcher? = nil,
        executableResolver: (@Sendable (String) -> URL?)? = nil
    ) {
        self.installPrefix = installPrefix
        self.managedNodeRuntime = managedNodeRuntime
        self.npmExecutableURL = npmExecutableURL
        self.installerFetcher = installerFetcher
        self.executableResolver = executableResolver
    }

    public func prepareCLIInstall(
        _ definition: LocalACPRuntimeDefinition
    ) async throws -> LocalACPInstallerPreview {
        if let packageSpec = definition.cliNpmPackageSpec {
            guard Self.isExactPackageSpec(packageSpec) else {
                throw LocalACPRuntimeInstallError.unpinnedPackage
            }
            guard let source = definition.cliInstallerSource,
                  LocalACPBoundedHTTPSDownloader.isSafeHTTPS(source)
            else { throw LocalACPRuntimeInstallError.unsafeSource }
            return LocalACPInstallerPreview(
                runtimeKind: definition.runtimeKind,
                source: source,
                sha256: nil,
                bytes: nil,
                packageSpec: packageSpec,
                verification: "npm-registry-integrity"
            )
        }
        let source = try cliInstallerSource(for: definition)
        let file = temporaryInstallerURL(for: definition)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = try await fetchInstaller(source, to: file)
        return LocalACPInstallerPreview(
            runtimeKind: definition.runtimeKind,
            source: source,
            sha256: try LocalACPManagedNodeRuntime.sha256Hex(fileAt: file),
            bytes: bytes,
            packageSpec: nil,
            verification: "sha256-redownload"
        )
    }

    public func install(
        _ definition: LocalACPRuntimeDefinition,
        component: LocalACPRuntimeInstallComponent,
        expectedSourceSHA256: String? = nil,
        expectedPackageSpec: String? = nil
    ) async throws -> URL {
        switch component {
        case .cli:
            try await installCLI(
                definition,
                expectedSourceSHA256: expectedSourceSHA256,
                expectedPackageSpec: expectedPackageSpec
            )
        case .adapter:
            try await installAdapter(definition)
        }
    }

    private func installCLI(
        _ definition: LocalACPRuntimeDefinition,
        expectedSourceSHA256: String?,
        expectedPackageSpec: String?
    ) async throws -> URL {
        if let packageSpec = definition.cliNpmPackageSpec {
            guard Self.isExactPackageSpec(packageSpec) else {
                throw LocalACPRuntimeInstallError.unpinnedPackage
            }
            guard expectedPackageSpec == packageSpec else {
                throw LocalACPRuntimeInstallError.confirmationRequired
            }
            return try await installNpmPackage(
                packageSpec,
                executableName: definition.commandName
            )
        }
        let source = try cliInstallerSource(for: definition)
        guard let expectedSourceSHA256,
              expectedSourceSHA256.count == 64,
              expectedSourceSHA256.allSatisfy({ $0.isHexDigit })
        else { throw LocalACPRuntimeInstallError.confirmationRequired }
        guard let interpreter = definition.cliInstallerInterpreter,
              ["sh", "bash"].contains(interpreter)
        else { throw LocalACPRuntimeInstallError.unsafeInterpreter }
        let file = temporaryInstallerURL(for: definition)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await fetchInstaller(source, to: file)
        let actualSHA256 = try LocalACPManagedNodeRuntime.sha256Hex(fileAt: file)
        guard actualSHA256 == expectedSourceSHA256.lowercased() else {
            throw LocalACPRuntimeInstallError.sourceDigestChanged
        }
        let result = try LocalACPProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/\(interpreter)"),
            arguments: [file.path] + definition.cliInstallerArguments,
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        guard result.succeeded else {
            throw LocalACPRuntimeInstallError.installFailed(
                result.combinedOutput
            )
        }
        let executableName =
            definition.underlyingCLIName ?? definition.commandName
        let executable = executableResolver?(executableName)
            ?? LocalACPRuntimeResolver.resolveExecutable(
                named: executableName
            )
        guard let executable else {
            throw LocalACPRuntimeInstallError.executableMissing(executableName)
        }
        return executable
    }

    private func installAdapter(
        _ definition: LocalACPRuntimeDefinition
    ) async throws -> URL {
        guard let package = definition.adapterPackage,
              let version = definition.minimumAdapterVersion,
              Self.isExactSemanticVersion(version)
        else {
            throw LocalACPRuntimeInstallError.notInstallable
        }
        let packageSpec = "\(package)@\(version)"
        return try await installNpmPackage(
            packageSpec,
            executableName: definition.commandName
        )
    }

    private func installNpmPackage(
        _ packageSpec: String,
        executableName: String
    ) async throws -> URL {
        guard Self.isExactPackageSpec(packageSpec) else {
            throw LocalACPRuntimeInstallError.unpinnedPackage
        }
        let npm: URL
        if let npmExecutableURL {
            npm = npmExecutableURL
        } else {
            npm = try await managedNodeRuntime.ensureInstalled()
        }
        try FileManager.default.createDirectory(
            at: installPrefix,
            withIntermediateDirectories: true
        )
        let searchDirectories = (
            [
                npm.deletingLastPathComponent().path,
                installPrefix.appending(path: "bin").path,
            ]
            + LocalACPRuntimeResolver.executableSearchDirectories()
        ).uniqued()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchDirectories.joined(separator: ":")
        environment["NO_UPDATE_NOTIFIER"] = "1"
        environment["npm_config_update_notifier"] = "false"
        let result = try LocalACPProcessRunner.run(
            executableURL: npm,
            arguments: [
                "install",
                "--global",
                "--prefix",
                installPrefix.path,
                packageSpec,
            ],
            environment: environment,
            currentDirectoryURL: installPrefix
        )
        guard result.succeeded else {
            throw LocalACPRuntimeInstallError.installFailed(
                result.combinedOutput
            )
        }
        let executable = installPrefix
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalACPRuntimeInstallError.executableMissing(
                executableName
            )
        }
        return executable
    }

    private func cliInstallerSource(
        for definition: LocalACPRuntimeDefinition
    ) throws -> URL {
        guard let source = definition.cliInstallerSource else {
            throw LocalACPRuntimeInstallError.notInstallable
        }
        guard LocalACPBoundedHTTPSDownloader.isSafeHTTPS(source) else {
            throw LocalACPRuntimeInstallError.unsafeSource
        }
        return source
    }

    private func fetchInstaller(_ source: URL, to file: URL) async throws -> Int {
        do {
            let reportedBytes: Int
            if let installerFetcher {
                reportedBytes = try await installerFetcher(
                    source,
                    file,
                    Self.maximumInstallerBytes
                )
            } else {
                reportedBytes = try await LocalACPBoundedHTTPSDownloader.download(
                    source,
                    to: file,
                    maximumBytes: Self.maximumInstallerBytes
                )
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path
            )
            let actualBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard actualBytes > 0,
                  actualBytes <= Self.maximumInstallerBytes,
                  actualBytes == reportedBytes
            else {
                throw LocalACPRuntimeInstallError.invalidInstallerSize
            }
            return actualBytes
        } catch let error as LocalACPBoundedDownloadError {
            switch error {
            case .unsafeURL:
                throw LocalACPRuntimeInstallError.unsafeSource
            case .tooLarge:
                throw LocalACPRuntimeInstallError.invalidInstallerSize
            case .invalidResponse, .transportFailed:
                throw LocalACPRuntimeInstallError.downloadFailed
            }
        }
    }

    private func temporaryInstallerURL(
        for definition: LocalACPRuntimeDefinition
    ) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "wovenmatter-\(definition.runtimeKind.rawValue)-\(UUID().uuidString).sh"
        )
    }

    static func isExactSemanticVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func isExactPackageSpec(_ value: String) -> Bool {
        guard let separator = value.lastIndex(of: "@"),
              separator != value.startIndex
        else { return false }
        let name = value[..<separator]
        let version = value[value.index(after: separator)...]
        return !name.isEmpty && isExactSemanticVersion(String(version))
    }
}

public enum LocalACPRuntimeInstallError: LocalizedError, Sendable, Equatable {
    case notInstallable
    case confirmationRequired
    case unsafeSource
    case unsafeInterpreter
    case downloadFailed
    case invalidInstallerSize
    case sourceDigestChanged
    case unpinnedPackage
    case installFailed(String)
    case executableMissing(String)

    public var errorDescription: String? {
        switch self {
        case .notInstallable:
            "This runtime does not have an automatic installation step."
        case .confirmationRequired:
            "Review and confirm the installer source and integrity details before running it."
        case .unsafeSource:
            "The installer source must be an HTTPS URL without embedded credentials."
        case .unsafeInterpreter:
            "The installer requested an unsupported script interpreter."
        case .downloadFailed:
            "Woven Matter could not securely download the installer."
        case .invalidInstallerSize:
            "The installer was empty or exceeded the allowed size."
        case .sourceDigestChanged:
            "The installer changed after review, so Woven Matter refused to run it."
        case .unpinnedPackage:
            "The npm package must use an exact semantic version."
        case .installFailed(let detail):
            "The runtime could not be installed: \(detail)"
        case .executableMissing(let command):
            "Installation completed, but \(command) was not found."
        }
    }
}

public enum LocalACPManagedNodeError: LocalizedError, Sendable {
    case downloadFailed
    case archiveTooLarge(Int)
    case hashMismatch(expected: String, actual: String)
    case invalidArchive(String)
    case unsafeArchiveEntry(String)
    case extractionFailed(String)
    case runtimeVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            "Woven Matter could not download its app-managed Node.js runtime."
        case .archiveTooLarge:
            "The downloaded Node.js archive exceeded the allowed size."
        case .hashMismatch:
            "The downloaded Node.js archive failed integrity verification."
        case .invalidArchive:
            "The downloaded Node.js archive could not be read."
        case .unsafeArchiveEntry:
            "The downloaded Node.js archive contained an unsafe path."
        case .extractionFailed:
            "Woven Matter could not extract its app-managed Node.js runtime."
        case .runtimeVerificationFailed:
            "The app-managed Node.js runtime did not pass verification."
        }
    }
}

struct LocalACPProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { terminationStatus == 0 }

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum LocalACPProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) throws -> LocalACPProcessResult {
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        output.fileHandleForWriting.closeFile()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return LocalACPProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: ""
        )
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        reduce(into: []) { result, element in
            if !result.contains(element) {
                result.append(element)
            }
        }
    }
}
