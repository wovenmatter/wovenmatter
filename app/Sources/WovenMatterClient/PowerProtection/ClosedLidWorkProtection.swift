import Foundation
import Observation
import ServiceManagement

public enum ClosedLidHelperSetup: Equatable, Sendable {
    case ready, approvalRequired, notRegistered, unavailable
}

/// Registration is a separate, explicit UI action. Execution owners only query
/// status/connect; starting a task or a login backend never asks for permission.
@MainActor
public enum ClosedLidHelperRegistration {
    public static var status: ClosedLidHelperSetup {
        guard (try? ClosedLidHelperIdentity.signingTeam()) != nil else { return .unavailable }
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .approvalRequired
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public static func prepareFromUserAction() throws {
        _ = try ClosedLidHelperIdentity.signingTeam()
        if service.status == .notRegistered { try service.register() }
        guard status == .ready || status == .approvalRequired else {
            throw ClosedLidPowerError.unavailable("The signed power helper is unavailable in this build.")
        }
    }

    public static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    private static var service: SMAppService { .daemon(plistName: ClosedLidHelperIdentity.plistName) }
}

@MainActor
protocol ClosedLidLeaseSending: AnyObject {
    func renew(_ policy: ClosedLidPolicy, completion: @escaping @MainActor (Bool, String?) -> Void)
    func close()
}

@MainActor
private final class ClosedLidXPCConnection: ClosedLidLeaseSending {
    private let connection: NSXPCConnection

    init() throws {
        let requirement = try ClosedLidHelperIdentity.requirement(
            team: ClosedLidHelperIdentity.signingTeam(), identifiers: [ClosedLidHelperIdentity.service])
        connection = NSXPCConnection(machServiceName: ClosedLidHelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: (any ClosedLidPowerProtocol).self)
        connection.resume()
    }

    func renew(_ policy: ClosedLidPolicy, completion: @escaping @MainActor (Bool, String?) -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in completion(false, "The power helper is disconnected. Retrying…") }
        } as? any ClosedLidPowerProtocol
        guard let proxy else { completion(false, "The power helper is unavailable."); return }
        proxy.renew(externalPower: policy.externalPower, batteryPower: policy.batteryPower) { active, error in
            Task { @MainActor in completion(active, error) }
        }
    }

    func close() { connection.invalidate() }
    isolated deinit { connection.invalidate() }
}

@Observable @MainActor
public final class ClosedLidWorkProtection {
    public private(set) var snapshot: ClosedLidProtectionSnapshot
    @ObservationIgnored private let ownsExecution: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let helperStatus: () -> ClosedLidHelperSetup
    @ObservationIgnored private let connect: () throws -> any ClosedLidLeaseSending
    @ObservationIgnored private var connection: (any ClosedLidLeaseSending)?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var requestStarted: ContinuousClock.Instant?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isWorking = false
    @ObservationIgnored private var stopped = false
    static let externalKey = "wovenmatter.closed-lid.external-power"
    static let batteryKey = "wovenmatter.closed-lid.battery-power"

    public convenience init(ownsExecution: Bool, defaults: UserDefaults = .standard) {
        self.init(ownsExecution: ownsExecution, defaults: defaults,
                  helperStatus: { ClosedLidHelperRegistration.status }, connect: { try ClosedLidXPCConnection() })
    }

    init(ownsExecution: Bool, defaults: UserDefaults,
         helperStatus: @escaping () -> ClosedLidHelperSetup,
         connect: @escaping () throws -> any ClosedLidLeaseSending) {
        self.ownsExecution = ownsExecution
        self.defaults = defaults
        self.helperStatus = helperStatus
        self.connect = connect
        snapshot = .init(policy: .init(externalPower: defaults.bool(forKey: Self.externalKey),
                                     batteryPower: defaults.bool(forKey: Self.batteryKey)))
    }

    public func setPolicy(_ policy: ClosedLidPolicy) {
        guard ownsExecution, !stopped else { return }
        defaults.set(policy.externalPower, forKey: Self.externalKey)
        defaults.set(policy.batteryPower, forKey: Self.batteryKey)
        snapshot.policy = policy
        reconcile()
    }

    public func applyBackendSnapshot(_ value: ClosedLidProtectionSnapshot) {
        guard !ownsExecution else { return }
        snapshot = value
    }

    public func setWorking(_ working: Bool) {
        guard ownsExecution, !stopped, isWorking != working else { return }
        isWorking = working
        reconcile()
    }

    public func stop() {
        stopped = true
        isWorking = false
        disconnect()
    }

    private func reconcile() {
        disconnect()
        guard ownsExecution, !stopped, isWorking, snapshot.policy.isEnabled else { return }
        beat()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                self.beat()
            }
        }
    }

    private func disconnect() {
        heartbeat?.cancel()
        heartbeat = nil
        generation = UUID()
        connection?.close()
        connection = nil
        requestStarted = nil
        snapshot.isProtecting = false
        snapshot.message = nil
    }

    // Internal for deterministic tests; no real timer or power operations needed.
    func beat() {
        guard ownsExecution, !stopped, isWorking, snapshot.policy.isEnabled else { return }
        guard helperStatus() == .ready else {
            connection?.close()
            connection = nil
            requestStarted = nil
            generation = UUID()
            snapshot.isProtecting = false
            snapshot.message = "Approve the power helper in macOS Login Items & Extensions to enable closed-lid protection."
            return
        }
        if let requestStarted {
            guard requestStarted.duration(to: .now) >= .seconds(6) else { return }
            connection?.close()
            connection = nil
            self.requestStarted = nil
            generation = UUID()
            snapshot.isProtecting = false
            snapshot.message = "The power helper stopped responding. Retrying…"
        }
        do {
            if connection == nil { connection = try connect() }
            requestStarted = .now
            let requestGeneration = generation
            connection?.renew(snapshot.policy) { [weak self] active, error in
                guard let self, self.generation == requestGeneration else { return }
                self.requestStarted = nil
                if self.snapshot.isProtecting != active { self.snapshot.isProtecting = active }
                if self.snapshot.message != error { self.snapshot.message = error }
                if error != nil {
                    self.connection?.close()
                    self.connection = nil
                    self.generation = UUID()
                }
            }
        } catch {
            requestStarted = nil
            snapshot.isProtecting = false
            snapshot.message = error.localizedDescription
        }
    }

    // Closing the XPC connection releases its helper lease; the helper watchdog
    // also expires it independently if the process disappears or stops responding.
    deinit { heartbeat?.cancel() }
}
