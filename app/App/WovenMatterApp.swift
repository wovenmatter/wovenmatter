import AppKit
import Darwin
import Foundation
import SwiftUI
import WovenMatterClient

struct WorkspaceProcessLeaseOwner: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let bundlePath: String

    init(
        processIdentifier: Int32,
        bundleIdentifier: String,
        bundlePath: String
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }

    init?(line: String) {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let processIdentifier = Int32(fields[0]),
              processIdentifier > 0,
              !fields[1].isEmpty,
              !fields[2].isEmpty else {
            return nil
        }
        self.processIdentifier = processIdentifier
        bundleIdentifier = String(fields[1])
        bundlePath = String(fields[2])
    }

    var line: String {
        "\(processIdentifier)\t\(bundleIdentifier)\t\(bundlePath)\n"
    }
}

enum WorkspaceProcessLeaseError: Error {
    case occupied(WorkspaceProcessLeaseOwner?)
}

enum WorkspaceProcessLeaseHandoffResult: Equatable {
    case activated(WorkspaceProcessLeaseOwner)
    case unavailable
}

struct WorkspaceProcessLeaseActivationCandidate {
    let owner: WorkspaceProcessLeaseOwner
    let isTerminated: () -> Bool
    let activate: () -> Bool
}

enum WorkspaceProcessLeaseStartupResult {
    case acquired(WorkspaceProcessLease)
    case handedOff(WorkspaceProcessLeaseOwner)
}

enum WorkspaceProcessLeaseStartupError: Error, Equatable, LocalizedError {
    case occupiedWithoutVerifiedIncumbent(
        attempts: Int,
        lastRecordedOwner: WorkspaceProcessLeaseOwner?
    )

    var errorDescription: String? {
        switch self {
        case .occupiedWithoutVerifiedIncumbent(let attempts, let owner):
            let ownerDescription = owner.map {
                "pid=\($0.processIdentifier) bundle=\($0.bundleIdentifier) path=\($0.bundlePath)"
            } ?? "unidentified owner"
            return "The workspace lease remained occupied after \(attempts) attempts, "
                + "and no live incumbent could be activated (\(ownerDescription))."
        }
    }
}

final class WorkspaceProcessLease {
    static let defaultMaximumAcquisitionAttempts = 11
    static let defaultRetryDelayMicroseconds: useconds_t = 50_000

    private static let appBundleIdentifiers = [
        "wovenmatter.desktop",
        "wovenmatter.desktop.dev",
    ]

    private let descriptor: Int32

    init(
        fileURL: URL = WorkspaceProcessLease.defaultFileURL(),
        owner: WorkspaceProcessLeaseOwner? = nil
    ) throws {
        let owner = owner ?? Self.currentOwner()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let chmodError = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: chmodError) ?? .EIO)
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EACCES || lockError == EAGAIN {
                let incumbent = (try? String(contentsOf: fileURL, encoding: .utf8))
                    .flatMap(WorkspaceProcessLeaseOwner.init(line:))
                throw WorkspaceProcessLeaseError.occupied(incumbent)
            }
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        do {
            try Self.write(owner.line, to: descriptor)
        } catch {
            _ = Darwin.lseek(descriptor, 0, SEEK_SET)
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.lseek(descriptor, 0, SEEK_SET)
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }

    static func defaultFileURL(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> URL {
        let supportDirectory = applicationSupportDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
        return supportDirectory.appending(
            path: "Woven Matter/workspace-owner.lock",
            directoryHint: .notDirectory
        )
    }

    static func resolveStartup(
        maximumAcquisitionAttempts: Int = defaultMaximumAcquisitionAttempts,
        retryDelayMicroseconds: useconds_t = defaultRetryDelayMicroseconds,
        acquire: () throws -> WorkspaceProcessLease = { try WorkspaceProcessLease() },
        handOff: (WorkspaceProcessLeaseOwner?) -> WorkspaceProcessLeaseHandoffResult = activateIncumbent,
        waitBeforeRetry: (useconds_t) -> Void = { _ = Darwin.usleep($0) }
    ) throws -> WorkspaceProcessLeaseStartupResult {
        precondition(maximumAcquisitionAttempts > 0)
        var lastRecordedOwner: WorkspaceProcessLeaseOwner?

        for attempt in 1...maximumAcquisitionAttempts {
            do {
                return .acquired(try acquire())
            } catch WorkspaceProcessLeaseError.occupied(let owner) {
                lastRecordedOwner = owner
                switch handOff(owner) {
                case .activated(let incumbent):
                    return .handedOff(incumbent)
                case .unavailable:
                    guard attempt < maximumAcquisitionAttempts else {
                        throw WorkspaceProcessLeaseStartupError
                            .occupiedWithoutVerifiedIncumbent(
                                attempts: maximumAcquisitionAttempts,
                                lastRecordedOwner: lastRecordedOwner
                            )
                    }
                    waitBeforeRetry(retryDelayMicroseconds)
                }
            }
        }

        // The precondition and loop bounds make this unreachable.
        throw WorkspaceProcessLeaseStartupError.occupiedWithoutVerifiedIncumbent(
            attempts: maximumAcquisitionAttempts,
            lastRecordedOwner: lastRecordedOwner
        )
    }

    static func acquireOrExit() -> WorkspaceProcessLease {
        do {
            switch try resolveStartup() {
            case .acquired(let lease):
                let owner = currentOwner()
                NSLog(
                    "Woven Matter workspace lease acquired: pid=%d bundle=%@ path=%@",
                    owner.processIdentifier,
                    owner.bundleIdentifier,
                    owner.bundlePath
                )
                return lease
            case .handedOff(let incumbent):
                NSLog(
                    "Woven Matter handed off to workspace owner: pid=%d bundle=%@ path=%@",
                    incumbent.processIdentifier,
                    incumbent.bundleIdentifier,
                    incumbent.bundlePath
                )
                Darwin.exit(EXIT_SUCCESS)
            }
        } catch {
            NSLog(
                "Woven Matter could not acquire its workspace lease: %@",
                error.localizedDescription
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func currentOwner() -> WorkspaceProcessLeaseOwner {
        WorkspaceProcessLeaseOwner(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path
        )
    }

    private static func activateIncumbent(
        _ owner: WorkspaceProcessLeaseOwner?
    ) -> WorkspaceProcessLeaseHandoffResult {
        verifyIncumbentHandoff(
            owner,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            candidateForProcessIdentifier: { processIdentifier in
                NSRunningApplication(processIdentifier: processIdentifier)
                    .flatMap { activationCandidate(for: $0) }
            },
            candidatesForBundleIdentifier: { bundleIdentifier in
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).compactMap { activationCandidate(for: $0) }
            }
        )
    }

    static func verifyIncumbentHandoff(
        _ owner: WorkspaceProcessLeaseOwner?,
        currentProcessIdentifier: Int32,
        candidateForProcessIdentifier: (Int32) -> WorkspaceProcessLeaseActivationCandidate?,
        candidatesForBundleIdentifier: (String) -> [WorkspaceProcessLeaseActivationCandidate]
    ) -> WorkspaceProcessLeaseHandoffResult {
        if let owner,
           appBundleIdentifiers.contains(owner.bundleIdentifier),
           owner.processIdentifier != currentProcessIdentifier,
           let candidate = candidateForProcessIdentifier(owner.processIdentifier),
           candidate.owner == owner,
           !candidate.isTerminated(),
           candidate.activate(),
           !candidate.isTerminated() {
            return .activated(owner)
        }
        for bundleIdentifier in appBundleIdentifiers {
            for candidate in candidatesForBundleIdentifier(bundleIdentifier) {
                guard candidate.owner.bundleIdentifier == bundleIdentifier,
                      candidate.owner.processIdentifier != currentProcessIdentifier,
                      !candidate.isTerminated(),
                      candidate.activate(),
                      !candidate.isTerminated() else {
                    continue
                }
                return .activated(candidate.owner)
            }
        }
        return .unavailable
    }

    private static func activationCandidate(
        for application: NSRunningApplication
    ) -> WorkspaceProcessLeaseActivationCandidate? {
        guard let bundleIdentifier = application.bundleIdentifier,
              let bundlePath = application.bundleURL?.standardizedFileURL.path else {
            return nil
        }
        return WorkspaceProcessLeaseActivationCandidate(
            owner: WorkspaceProcessLeaseOwner(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundlePath: bundlePath
            ),
            isTerminated: { application.isTerminated },
            activate: { application.activate(options: [.activateAllWindows]) }
        )
    }

    private static func write(_ string: String, to descriptor: Int32) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw currentPOSIXError()
        }
        let data = Data(string.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard result > 0 else { throw currentPOSIXError() }
                written += result
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@main
struct WovenMatterApp: App {
    private let workspaceProcessLease: WorkspaceProcessLease?
    @State private var applicationModel: ApplicationModel
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var sidebarStyleRawValue = DashboardSidebarStyle.defaultStyle.rawValue

    init() {
        if let commandIndex = CommandLine.arguments.firstIndex(of: "--woven-note-cli") {
            Darwin.exit(WovenNoteCommandLine.run(
                arguments: Array(CommandLine.arguments.dropFirst(commandIndex + 1)),
                environment: ProcessInfo.processInfo.environment
            ))
        }
        let environment = ProcessInfo.processInfo.environment
        let isRunningUnitTests = environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath")
        workspaceProcessLease = isRunningUnitTests
            ? nil
            : WorkspaceProcessLease.acquireOrExit()
        _applicationModel = State(initialValue: ApplicationModel())
        if !isRunningUnitTests {
            Self.markUpdateReadyIfRequested()
        }
    }

    private static func markUpdateReadyIfRequested() {
        guard let flagIndex = CommandLine.arguments.firstIndex(
            of: "--woven-update-ready"
        ),
        CommandLine.arguments.indices.contains(flagIndex + 1) else {
            return
        }
        let marker = URL(
            fileURLWithPath: CommandLine.arguments[flagIndex + 1]
        ).standardizedFileURL
        let updatesDirectory = LocalACPManagedRuntimePaths.applicationSupportDirectory
            .appending(path: "Updates", directoryHint: .isDirectory)
            .standardizedFileURL
        guard marker.deletingLastPathComponent() == updatesDirectory,
              marker.lastPathComponent.hasPrefix(".ready-") else {
            return
        }
        try? Data().write(to: marker, options: .atomic)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: applicationModel)
                .frame(minWidth: 760, minHeight: 640)
                .scrollIndicators(.never)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didResignActiveNotification
                    )
                ) { _ in
                    applicationModel.flushNoteDrafts()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification
                    )
                ) { _ in
                    applicationModel.flushNoteDrafts()
                    applicationModel.shutdownLocalACPSessions()
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Workspace") {
                Button("Refresh Workspace") {
                    Task { await applicationModel.refreshWorkspace() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Appearance") {
                Picker("Theme", selection: $themeRawValue) {
                    ForEach(DashboardTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                Divider()
                Picker("Sidebar Layout", selection: $sidebarStyleRawValue) {
                    ForEach(DashboardSidebarStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
            }
        }

        Settings {
            SettingsView(model: applicationModel)
                .scrollIndicators(.never)
        }
    }
}
