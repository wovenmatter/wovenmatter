import AppKit
import Darwin
import Foundation
import SwiftUI
import WovenMatterDashboardStore
import WovenMatterClient
import WovenMatterCore

/// Client/snapshot variants are isolated; an explicit live host uses production's lease.
/// Release builds always use the established workspace directory.
enum WovenMatterWorkspacePaths {
    static var folderName: String {
        if let mode = DevelopmentLaunch.mode, let instance = DevelopmentLaunch.instance {
            return mode.workspaceFolder(instance: instance)
        }
        #if DEBUG
        let prefix = "wovenmatter.desktop.dev."
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix(prefix) {
            let variant = String(identifier.dropFirst(prefix.count))
            if !variant.isEmpty, variant.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                return "Woven Matter Dev/" + variant
            }
        }
        #endif
        return "Woven Matter"
    }
}

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
        ).first,
        isolatedDirectory: URL? = CompanionTestWorkspace.supportDirectory,
        role: LocalExecutionRole = .current
    ) -> URL {
        if let isolated = isolatedDirectory {
            return isolated.appending(path: role.leaseFileName)
        }
        let supportDirectory = applicationSupportDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
        return supportDirectory.appending(
            path: WovenMatterWorkspacePaths.folderName + "/" + role.leaseFileName,
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
            // A service must never use GUI activation as proof of execution
            // ownership. In particular, the frontend has a different lease.
            if LocalExecutionRole.current == .backend {
                do { return try WorkspaceProcessLease() }
                catch WorkspaceProcessLeaseError.occupied {
                    NSLog("Woven Matter backend already has an execution owner")
                    Darwin.exit(EXIT_SUCCESS)
                }
            }
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
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        candidateForProcessIdentifier: (Int32) -> WorkspaceProcessLeaseActivationCandidate?,
        candidatesForBundleIdentifier: (String) -> [WorkspaceProcessLeaseActivationCandidate]
    ) -> WorkspaceProcessLeaseHandoffResult {
        let identifiers: [String]
        if let currentBundleIdentifier, currentBundleIdentifier.hasPrefix("wovenmatter.desktop.dev.") {
            identifiers = [currentBundleIdentifier]
        } else { identifiers = appBundleIdentifiers }
        if let owner,
           identifiers.contains(owner.bundleIdentifier),
           owner.processIdentifier != currentProcessIdentifier,
           let candidate = candidateForProcessIdentifier(owner.processIdentifier),
           candidate.owner == owner,
           !candidate.isTerminated(),
           candidate.activate(),
           !candidate.isTerminated() {
            return .activated(owner)
        }
        for bundleIdentifier in identifiers {
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
              let bundlePath = application.bundleURL?.standardizedFileURL.path,
              application.activationPolicy == .regular else {
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

/// Actions belong to the active workspace window, including a Dev client's
/// local execution surface. Settings and setup windows publish no workspace actions.
struct WorkspaceMenuActions {
    var newChat: @MainActor () -> Void
    var newNote: @MainActor () -> Void
    var newBrowserTab: @MainActor () -> Void
    var refresh: @MainActor () -> Void
}

private struct WorkspaceMenuActionsKey: FocusedValueKey {
    typealias Value = WorkspaceMenuActions
}

extension FocusedValues {
    var workspaceMenuActions: WorkspaceMenuActions? {
        get { self[WorkspaceMenuActionsKey.self] }
        set { self[WorkspaceMenuActionsKey.self] = newValue }
    }
}

#if !COMPANION_FACADE_TESTS
@main
enum WovenMatterEntryPoint {
    @MainActor static func main() {
        // Service helpers must never initialize AppKit, SwiftUI, or a workspace.
        if let status = CompanionServeSupervisor.dispatch(arguments: CommandLine.arguments) {
            Darwin.exit(status)
        }
        // Dispatch before App.main and its delegate adaptor can initialize
        // NSApplication. A service is not a second instance of the GUI app:
        // LaunchServices and Sparkle must only see the frontend.
        if LocalExecutionRole.current == .backend {
            runBackend()
        }
        // SwiftUI's delegate adaptor can initialize NSApplication before App.init.
        // Install CEF's required AppKit subclass first, without loading Chromium.
        if LocalExecutionRole.current != .backend {
            WMBrowserRuntime.prepareApplication()
        }
        WovenMatterApp.main()
    }

    @MainActor private static func runBackend() -> Never {
        do {
            try DevelopmentLaunch.validate()
            if DevelopmentLaunch.mode == nil,
               UserDefaults.standard.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey) {
                Darwin.exit(EXIT_SUCCESS)
            }
            KeychainAccess.enforceCentralAuthorization()
            let lease = WorkspaceProcessLease.acquireOrExit()
            try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(
                LocalExecutionRole.backendSocketURL(workspaceDirectory:
                    WorkspaceProcessLease.defaultFileURL().deletingLastPathComponent()))
            let model = ApplicationModel(startsAutomatically: false)
            model.backgroundServerTermination = { [weak model] in
                Task { @MainActor in
                    await model?.finishBackendShutdown()
                    WovenMatterBackendProcess.stop()
                }
            }
            WovenMatterBackendProcess.run(start: {
                Task {
                    await model.startBackendService()
                    if case .failed = model.state {
                        // No usable endpoint: allow launchd to retry this failure.
                        Darwin.exit(EXIT_FAILURE)
                    }
                    model.retry()
                }
            }, terminate: {
                let response = await model.handleBackendRequest(.init(method: "server.stop",
                    payload: (try? JSONEncoder().encode(BackgroundServerStopRequest(confirmed: true))) ?? Data()))
                if let error = response.error { NSLog("Background shutdown deferred: %@", error) }
                return response.error == nil
            })
            withExtendedLifetime((model, lease)) {}
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            NSLog("Woven Matter backend startup failed: %@", error.localizedDescription)
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

struct WorkspaceMenuCommands: Commands {
    @FocusedValue(\.workspaceMenuActions) private var actions
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var sidebarStyleRawValue = DashboardSidebarStyle.defaultStyle.rawValue

    private var dictationTitle: String {
        if DictationModel.shared.isRecording { return "Stop Dictation" }
        return DictationModel.shared.retainedTranscript == nil ? "Start Dictation" : "Insert Dictation"
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu("File") {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("New Browser Tab") { actions?.newBrowserTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button(dictationTitle) { DictationModel.shared.toggleActiveEditor() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(DictationModel.shared.shortcutEditor?.ticket() == nil
                    || DictationModel.shared.phase == .finishing)
            Divider()
            Button("Refresh Workspace") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)
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
}

struct WovenMatterApp: App {
    @NSApplicationDelegateAdaptor(WovenMatterLifecycleDelegate.self) private var lifecycleDelegate
    private let workspaceProcessLease: WorkspaceProcessLease?
    @State private var applicationModel: ApplicationModel

    init() {

        let environment = ProcessInfo.processInfo.environment
        let isRunningUnitTests = environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath")
        if !isRunningUnitTests, CompanionTestWorkspace.supportDirectory == nil {
            do { try DevelopmentLaunch.validate() }
            catch {
                NSLog("Development launch refused: %@", error.localizedDescription)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        if !isRunningUnitTests, LocalExecutionRole.current != .backend {
            HarnessSetupPresentation.shared.prepareForLaunch()
        }
        if !isRunningUnitTests { KeychainAccess.enforceCentralAuthorization() }
        workspaceProcessLease = isRunningUnitTests
            ? nil
            : WorkspaceProcessLease.acquireOrExit()
        _applicationModel = State(initialValue: ApplicationModel())
        if !isRunningUnitTests {
            Self.markUpdateReadyIfRequested()
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
                ProductAnalyticsModel.markUpdateLaunched(version: version, build: build)
            }
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
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(buildString) else { return }
        // A helper launch confirms replacement; clicking Install alone never does.
        ProductAnalyticsModel.markUpdateLaunched(marker: marker, version: version, build: build)
        try? Data().write(to: marker, options: .atomic)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: applicationModel)
                .onAppear {
                    applicationModel.configureDictationHistory()
                    lifecycleDelegate.model = applicationModel
                    DesktopUpdater.shared.start(model: applicationModel)
                    lifecycleDelegate.prepareBrowserTermination = { await WorkspaceAssetSession.shutdown() }
                }
                .frame(minWidth: 760, minHeight: 640)
                .scrollIndicators(.never)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didResignActiveNotification
                    )
                ) { _ in
                    Task { await applicationModel.flushNoteDrafts() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification)) { _ in
                    // AppKit focus is not observable. Publish changes after its
                    // event cycle so the dictation command's enabled state follows it.
                    DictationModel.shared.refreshShortcutEditor()
                }

        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands { WorkspaceMenuCommands() }

        Window("Set up Woven Matter", id: HarnessSetupPresentation.windowID) {
            if applicationModel.isLibraryClient {
                if let execution = applicationModel.libraryClient.localExecution {
                    HarnessSetupView(model: execution.model)
                } else {
                    Text("Connect this Mac to its library in Settings → Devices before setting up harnesses.")
                        .frame(width: 640, height: 240)
                }
            } else if applicationModel.state == .ready {
                HarnessSetupView(model: applicationModel)
            } else {
                ProgressView("Opening workspace…").frame(width: 740, height: 640)
            }
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            Group {
                if applicationModel.isLibraryClient { CentralLibraryClientSettings(model: applicationModel.libraryClient, application: applicationModel) }
                else { SettingsView(model: applicationModel) }
            }.scrollIndicators(.never)
        }
    }
}
#endif
