import Foundation
import WovenMatterClient

/// The engine bots run in on this Mac: Woven's own Linux VM running Docker Engine.
/// The bots host codes only against this protocol. See docs/architecture/WOVEN_EVERYWHERE.md
/// (Bots → Engine → Mac VM).
@MainActor
protocol BotEngineHost: AnyObject {
    /// Starts the VM if needed, applies `resources`, and returns once Docker Engine
    /// answers on the returned Unix socket. Repeated calls while running are cheap.
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus
    func status() async -> BotEngineStatus
    /// Applies the RAM pool and disk cap to the VM. Raising disk is immediate;
    /// lowering it stops at what is already used.
    func apply(resources: BotResourceSettings) async throws
    /// What bots already store, for the disk cap's lower bound. nil when unknown.
    /// Previews need nothing here: the runtime carries them over Engine API exec streams.
    func diskUsedByBots() async -> Int64?
    /// Updates the engine itself (the VM's guest packages and Docker Engine), behind a
    /// snapshot that is restored on failure. Returns when the engine is ready again;
    /// throws with the reason when the update failed and was rolled back.
    func update() async throws
    /// Stops containers and the VM, for quit or when bots are turned off here.
    func stop() async
    /// Progress while starting or updating (download, first boot, failures), so the
    /// Bots UI shows it as it happens instead of after `ensureRunning` returns.
    var onStatusChange: (@MainActor (BotEngineStatus) -> Void)? { get set }
}

struct BotEngineStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case stopped, starting, running, updating, failed, unavailable }
    var state: State
    /// The Docker Engine API socket under the app's support directory.
    var socketPath: String?
    /// What the UI shows: progress while starting or updating, the reason for a failure,
    /// or a note about a running engine (a pending restart, a rolled-back update).
    var message: String?
}

/// For Macs that cannot run the VM: bots stay off with the reason.
@MainActor
final class UnavailableBotEngineHost: BotEngineHost {
    private let reason: String
    var onStatusChange: (@MainActor (BotEngineStatus) -> Void)?
    init(reason: String) { self.reason = reason }
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus {
        throw BotsError.unavailable(reason)
    }
    func status() async -> BotEngineStatus { .init(state: .unavailable, message: reason) }
    func apply(resources: BotResourceSettings) async throws {}
    func diskUsedByBots() async -> Int64? { nil }
    func update() async throws { throw BotsError.unavailable(reason) }
    func stop() async {}
}

/// The parts of `WovenVMController` the bots host uses, so tests can script the VM.
protocol BotVMControl: Sendable {
    var engineSocket: URL { get }
    func ensureRunning() async throws -> WovenVMStatus
    func status() async throws -> WovenVMStatus
    func applyResources(_ resources: WovenVMResources) async throws -> WovenVMStatus
    func update() async throws -> WovenVMStatus
    func stop() async throws
}

extension WovenVMController: BotVMControl {}

/// Bots on this Mac run in the Woven VM: the pool is the VM's memory and the disk cap its
/// data disk cap. Per-bot RAM is not the VM's business: it is each container's limit in
/// the runtime config.
@MainActor
final class WovenVMBotEngineHost: BotEngineHost {
    private let vm: any BotVMControl
    private let pollInterval: Duration
    private let readyTimeout: Duration
    /// The helper starts in `stopped` and moves on once its boot sequence begins.
    private let stoppedGrace: Duration
    var onStatusChange: (@MainActor (BotEngineStatus) -> Void)?
    private(set) var last: BotEngineStatus

    init(vm: any BotVMControl, pollInterval: Duration = .seconds(1), readyTimeout: Duration = .seconds(3_600),
         stoppedGrace: Duration = .seconds(60)) {
        self.vm = vm
        self.pollInterval = pollInterval
        self.readyTimeout = readyTimeout
        self.stoppedGrace = stoppedGrace
        last = .init(state: .stopped, socketPath: vm.engineSocket.path)
    }

    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus {
        do {
            publish(try await vm.ensureRunning())
            // Before the first boot this sizes the VM; later a pool change applies through the
            // balloon at once and exactly when the helper next restarts the idle VM.
            publish(try await vm.applyResources(Self.vmResources(resources)))
            return publish(try await waitUntilReady())
        } catch let error as WovenVMError {
            let status = BotEngineStatus(state: .failed, socketPath: vm.engineSocket.path, message: Self.failureText(error))
            publish(status)
            throw BotsError.unavailable(status.message ?? error.localizedDescription)
        }
    }

    func status() async -> BotEngineStatus {
        guard let current = try? await vm.status() else {
            // No control socket: the helper is not running (bots off, or not started yet).
            return last.state == .failed ? last : .init(state: .stopped, socketPath: vm.engineSocket.path)
        }
        return Self.describe(current)
    }

    func apply(resources: BotResourceSettings) async throws {
        do { publish(try await vm.applyResources(Self.vmResources(resources))) }
        catch let error as WovenVMError { throw BotsError.unavailable(Self.failureText(error)) }
    }

    func diskUsedByBots() async -> Int64? {
        guard let used = try? await vm.status().resources?.guestDiskUsedBytes else { return nil }
        return Int64(clamping: used)
    }

    func update() async throws {
        do {
            let before = try await vm.status()
            guard before.phase == .ready else {
                throw BotsError.unavailable("The bots VM can update only while it is running.")
            }
            publish(try await vm.update())
            // The helper starts the update in the background: wait for it to begin, then to end.
            let started = ContinuousClock.now
            var current = try await vm.status()
            while current.phase == .ready, ContinuousClock.now - started < stoppedGrace {
                try await Task.sleep(for: pollInterval)
                current = try await vm.status()
                publish(current)
            }
            current = try await waitUntilReady()
            publish(current)
            if let failure = current.updateFailure {
                throw BotsError.unavailable("The bots VM update failed and was rolled back: \(failure)")
            }
        } catch let error as WovenVMError {
            throw BotsError.unavailable(Self.failureText(error))
        }
    }

    func stop() async {
        try? await vm.stop()
        publish(.init(state: .stopped, socketPath: vm.engineSocket.path))
    }

    // MARK: Status

    private func waitUntilReady() async throws -> WovenVMStatus {
        let clock = ContinuousClock(), started = clock.now
        while true {
            let current: WovenVMStatus
            do { current = try await vm.status() } catch let error as WovenVMError {
                // The helper may be restarting (launchd brings it back); give it the grace period.
                guard clock.now - started < stoppedGrace else { throw error }
                try await Task.sleep(for: pollInterval)
                continue
            }
            publish(current)
            switch current.phase {
            case .ready: return current
            case .failed: throw WovenVMError.failed(current.failure ?? "The bots VM failed.")
            case .stopped where clock.now - started >= stoppedGrace:
                throw WovenVMError.unavailable("The bots VM did not start.")
            default:
                guard clock.now - started < readyTimeout else {
                    throw WovenVMError.unavailable("The bots VM did not become ready in time.")
                }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    @discardableResult
    private func publish(_ status: WovenVMStatus) -> BotEngineStatus {
        publish(Self.describe(status))
    }

    @discardableResult
    private func publish(_ status: BotEngineStatus) -> BotEngineStatus {
        if status != last {
            last = status
            onStatusChange?(status)
        }
        return status
    }

    /// The pool is the VM's memory, the disk cap its data disk cap. The VM needs at least
    /// 1 GB of memory and 10 GB of disk for the guest and Docker Engine.
    static func vmResources(_ settings: BotResourceSettings) -> WovenVMResources {
        WovenVMResources(memoryBytes: settings.poolBytes.map { max(UInt64(clamping: $0), WovenVMResources.minimumMemoryBytes) },
                         diskBytes: settings.diskBytes.map { max(UInt64(clamping: $0), WovenVMResources.minimumDiskBytes) })
    }

    /// The VM's status as the Bots UI says it.
    static func describe(_ status: WovenVMStatus) -> BotEngineStatus {
        let socket = status.engineSocket
        func step(_ lead: String) -> String {
            guard let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return lead + "…" }
            return "\(lead): \(detail)…"
        }
        switch status.phase {
        case .ready:
            var notes: [String] = []
            if let failure = status.updateFailure { notes.append("The last bots VM update failed and was rolled back: \(failure)") }
            if status.resources?.restartPending == true {
                notes.append("The new RAM pool applies fully when the bots VM restarts, which happens on its own once no bot is running.")
            }
            return .init(state: .running, socketPath: socket, message: notes.isEmpty ? nil : notes.joined(separator: " "))
        case .stopped:
            return .init(state: .stopped, socketPath: socket, message: nil)
        case .downloading:
            let percent = status.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            return .init(state: .starting, socketPath: socket,
                         message: "Downloading Linux for the bots VM (first start only)…\(percent)")
        case .preparing:
            return .init(state: .starting, socketPath: socket, message: step("Preparing the bots VM"))
        case .booting:
            return .init(state: .starting, socketPath: socket, message: step("Starting the bots VM"))
        case .provisioning:
            return .init(state: .starting, socketPath: socket, message: step("Setting up the bots VM"))
        case .updating:
            return .init(state: .updating, socketPath: socket, message: step("Updating the bots VM"))
        case .failed:
            return .init(state: .failed, socketPath: socket,
                         message: "The bots VM failed: \(status.failure ?? "no reason was given"). Turn bots off and on to try again.")
        }
    }

    static func failureText(_ error: WovenVMError) -> String {
        switch error {
        case .failed(let message):
            message.hasPrefix("The bots VM") ? message : "The bots VM failed: \(message)"
        case .unavailable(let message), .invalid(let message):
            message
        }
    }
}

enum BotEngineHostFactory {
    /// The Woven VM where this Mac can run it; otherwise an engine that says why not.
    @MainActor static var make: @MainActor (_ supportDirectory: URL) -> any BotEngineHost = { supportDirectory in
        if let vm = WovenVMController.forApp(supportDirectory: supportDirectory) { return WovenVMBotEngineHost(vm: vm) }
        return UnavailableBotEngineHost(reason: unavailableReason())
    }

    static func unavailableReason(isAppleSilicon: Bool = {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }()) -> String {
        isAppleSilicon
            ? "This build of Woven Matter is missing its bots VM helper. Reinstall Woven Matter to run bots on this Mac."
            : "Bots on this Mac need Apple silicon. Run them on another Mac or a Linux machine."
    }
}
