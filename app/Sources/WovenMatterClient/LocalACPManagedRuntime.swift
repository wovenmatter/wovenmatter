import CryptoKit
import Foundation

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

        let data: Data
        if let downloader {
            data = try await downloader(artifact.downloadURL)
        } else {
            data = try await Self.download(artifact.downloadURL)
        }
        guard data.count <= Self.maximumArchiveBytes else {
            throw LocalACPManagedNodeError.archiveTooLarge(data.count)
        }
        let actualHash = Self.sha256Hex(data)
        guard actualHash == artifact.sha256.lowercased() else {
            throw LocalACPManagedNodeError.hashMismatch(
                expected: artifact.sha256,
                actual: actualHash
            )
        }

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

        try data.write(to: archiveURL, options: .atomic)
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

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LocalACPManagedNodeError.downloadFailed
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public actor LocalACPRuntimeInstaller {
    public let installPrefix: URL
    private let managedNodeRuntime: LocalACPManagedNodeRuntime
    private let npmExecutableURL: URL?
    private let shellExecutableURL: URL
    private let executableResolver: (@Sendable (String) -> URL?)?

    public init(
        installPrefix: URL = LocalACPManagedRuntimePaths.nodeToolsPrefix,
        managedNodeRuntime: LocalACPManagedNodeRuntime = LocalACPManagedNodeRuntime(),
        npmExecutableURL: URL? = nil,
        shellExecutableURL: URL = URL(fileURLWithPath: "/bin/zsh"),
        executableResolver: (@Sendable (String) -> URL?)? = nil
    ) {
        self.installPrefix = installPrefix
        self.managedNodeRuntime = managedNodeRuntime
        self.npmExecutableURL = npmExecutableURL
        self.shellExecutableURL = shellExecutableURL
        self.executableResolver = executableResolver
    }

    public func install(
        _ definition: LocalACPRuntimeDefinition,
        component: LocalACPRuntimeInstallComponent
    ) async throws -> URL {
        switch component {
        case .cli:
            try installCLI(definition)
        case .adapter:
            try await installAdapter(definition)
        }
    }

    private func installCLI(
        _ definition: LocalACPRuntimeDefinition
    ) throws -> URL {
        guard let command = definition.cliInstallCommand else {
            throw LocalACPRuntimeInstallError.notInstallable
        }
        let result = try LocalACPProcessRunner.run(
            executableURL: shellExecutableURL,
            arguments: ["-l", "-c", command],
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
        guard let package = definition.adapterPackage else {
            throw LocalACPRuntimeInstallError.notInstallable
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
                package,
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
            .appending(path: definition.commandName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalACPRuntimeInstallError.executableMissing(
                definition.commandName
            )
        }
        return executable
    }
}

public enum LocalACPRuntimeInstallError: LocalizedError, Sendable {
    case notInstallable
    case installFailed(String)
    case executableMissing(String)

    public var errorDescription: String? {
        switch self {
        case .notInstallable:
            "This runtime does not have an automatic installation step."
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
