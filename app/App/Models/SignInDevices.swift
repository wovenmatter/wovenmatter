import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// A device whose sign-ins Settings → Subscriptions & API Keys manages. Every device
/// stores and renews its own; the app only shows them and passes the user's input to
/// that device's background server.
struct SignInDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case thisMac, mac, linux }
    static let localID = "local"

    /// `local`, `mac:<member device id>` or `linux:<registry workspace id>`.
    var id: String
    var kind: Kind
    /// The device's Tailnet name.
    var name: String
    /// Bots are turned on there; they use this device's sign-ins.
    var runsBots: Bool
    /// The device's member ID (another Mac, a Linux host), as bots machines name it.
    var memberID: String?
    /// The registry workspace it serves (a Linux workspace's lowercased UUID).
    var workspaceID: String?

    static func macID(_ memberID: String) -> String { "mac:" + memberID.lowercased() }
    static func linuxID(_ workspaceID: String) -> String { "linux:" + workspaceID.lowercased() }
    static func linuxID(_ workspace: UUID) -> String { linuxID(workspace.uuidString) }
    static func kind(of id: String) -> Kind {
        id.hasPrefix("mac:") ? .mac : id.hasPrefix("linux:") ? .linux : .thisMac
    }
    /// The member device ID of another Mac.
    static func memberID(of id: String) -> String? { id.hasPrefix("mac:") ? String(id.dropFirst(4)) : nil }
    /// The Linux workspace a device ID names.
    static func linuxWorkspace(of id: String) -> UUID? { id.hasPrefix("linux:") ? UUID(uuidString: String(id.dropFirst(6))) : nil }
    /// The device that holds the sign-ins of a Pi Durable chat-settings scope:
    /// this Mac for `global`/`local`, a Linux workspace for its ID.
    static func id(forScope scope: String) -> String {
        UUID(uuidString: scope).map { linuxID($0) } ?? localID
    }
    /// The device a bots machine is (`BotMachine.id`, its member device ID), for
    /// opening Subscriptions & API Keys from a bot.
    static func id(forBotMachine machineID: String, in devices: [SignInDevice]) -> String? {
        let id = machineID.lowercased()
        return devices.first { $0.memberID?.lowercased() == id || $0.workspaceID == id }?.id
    }
    /// The first label of a tailnet address (`name.tailnet.ts.net`), the device's Tailnet name.
    static func tailnetName(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        return label.isEmpty ? nil : label
    }

    /// This Mac, then other Macs, then Linux workspaces, each by name.
    static func ordered(_ devices: [SignInDevice]) -> [SignInDevice] {
        let rank: [Kind: Int] = [.thisMac: 0, .mac: 1, .linux: 2]
        return devices.sorted {
            rank[$0.kind]! != rank[$1.kind]! ? rank[$0.kind]! < rank[$1.kind]!
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// A Linux host's own sign-ins (`GET`/`POST v1/sign-ins`): account labels and
/// server addresses, never a secret.
struct DeviceSignIns: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        var id: String
        var label: String
        var isSelected: Bool
        var createdAt: String?
    }
    struct Server: Decodable, Sendable {
        var id: String
        var url: String
        var models: [String]
        var verifiedAt: String?
    }
    var accounts: [String: [Account]]
    var servers: [Server]

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    var providerAccounts: [String: [ProviderConnectionAccounts.Account]] {
        accounts.mapValues { $0.map { .init(id: $0.id, label: $0.label, createdAt: Self.date($0.createdAt), isSelected: $0.isSelected) } }
    }
    var localServers: [LocalModelServer] {
        servers.map { LocalModelServer(id: $0.id, url: $0.url, models: $0.models, verifiedAt: Self.date($0.verifiedAt) ?? .now) }
    }
}

/// One change to a Linux host's sign-ins. An API key is sent once, in this body.
struct DeviceSignInChange: Encodable, Sendable {
    var action: String
    var provider: String? = nil
    var id: String? = nil
    var key: String? = nil
    var label: String? = nil
    var offset: Int? = nil
    var url: String? = nil
    var server: LocalModelServer? = nil
}

extension ApplicationModel {
    /// The devices whose sign-ins this Mac can manage: itself, every other Mac and
    /// every Linux workspace it can reach with its member key.
    func signInDevices() async -> [SignInDevice] {
        let machines = bots.machines
        func runsBots(_ memberID: String?) -> Bool {
            guard let memberID else { return false }
            return machines.first { $0.id.lowercased() == memberID.lowercased() }?.socket != nil
        }
        let thisName = SignInDevice.tailnetName(libraryHost.endpoint?.host) ?? DevelopmentLaunch.deviceName()
        var devices = [SignInDevice(id: SignInDevice.localID, kind: .thisMac, name: thisName,
                                    runsBots: bots.thisMachine?.socket != nil, memberID: bots.thisMachineID)]
        var linux: Set<String> = []
        for target in await memberBotTargets() {
            let host = target.workspace.endpoint?.host
            switch target.workspace.kind {
            case .mac:
                devices.append(.init(id: SignInDevice.macID(target.audience), kind: .mac,
                    name: SignInDevice.tailnetName(host) ?? target.workspace.name, runsBots: runsBots(target.audience),
                    memberID: target.audience, workspaceID: target.workspace.id))
            case .linux:
                let configured = remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == target.workspace.id }
                linux.insert(target.workspace.id)
                devices.append(.init(id: SignInDevice.linuxID(target.workspace.id), kind: .linux,
                    name: SignInDevice.tailnetName(host) ?? SignInDevice.tailnetName(configured?.hostName) ?? target.workspace.name,
                    runsBots: runsBots(target.audience), memberID: target.audience, workspaceID: target.workspace.id))
            default: break
            }
        }
        // A workspace this Mac added whose member identity has not synchronized yet.
        for configuration in remoteWorkspaces.workspaces where !linux.contains(configuration.id.uuidString.lowercased()) {
            let workspaceID = configuration.id.uuidString.lowercased()
            let machine = machines.first { $0.workspaceID == workspaceID }
            devices.append(.init(id: SignInDevice.linuxID(workspaceID), kind: .linux,
                name: SignInDevice.tailnetName(configuration.hostName) ?? configuration.name,
                runsBots: machine?.socket != nil, memberID: machine?.id, workspaceID: workspaceID))
        }
        return SignInDevice.ordered(devices)
    }

    /// How this Mac's background server reaches another Mac's sign-ins: that Mac's
    /// `/v1/connections/*` routes, signed with this Mac's member key.
    func signInPeerTransport(memberID: String) -> (String, Data) async throws -> Data {
        { [weak self] method, payload in
            guard let self else { throw CancellationError() }
            guard let target = await self.memberBotTargets().first(where: { $0.audience == memberID.lowercased() && $0.workspace.kind == .mac }) else {
                throw DefaultAgentError.message("That Mac isn't reachable from this Mac right now.")
            }
            let client = try await self.botsClient(for: target.workspace)
            let path = method == "connections.command" ? "v1/connections/command" : "v1/connections/snapshot"
            do {
                let snapshot: BackendConnectionsSnapshot = try await client.request(path, method: "POST",
                    body: method == "connections.command" ? payload : Data("{}".utf8), timeout: 55)
                return try JSONEncoder().encode(snapshot)
            } catch let error as MemberSignedHTTPError {
                if case .http(let status, _, let message) = error {
                    if status == 404 || status == 426 {
                        throw DefaultAgentError.message("Update Woven Matter on \(target.workspace.name) to manage its sign-ins from here.")
                    }
                    throw DefaultAgentError.message(message.isEmpty ? "\(target.workspace.name) did not accept this change." : message)
                }
                throw DefaultAgentError.message("\(target.workspace.name) could not be reached.")
            }
        }
    }

    // MARK: This Mac's side, for other Macs

    /// Paths another Mac's Settings → Subscriptions & API Keys calls here.
    nonisolated static func servesMemberSignIns(_ path: String) -> Bool {
        path == "/v1/connections/command" || path == "/v1/connections/snapshot"
    }

    /// A signed Mac member's sign-in command, run on this Mac with this Mac's own
    /// Keychain, helper and renewal. Each member gets its own settings model, so it
    /// never disturbs what this Mac's windows show. Only this device is reachable:
    /// no relaying to Linux hosts or further Macs.
    func memberSignIns(_ request: LibraryHTTPRequest, path: String, memberID: String) async -> LibraryHTTPResponse {
        let session = memberSignInSessions[memberID] ?? {
            let value = MemberSignInSession(model: Self.memberSignInModel())
            // A member gone for a while with nothing running is released.
            value.onRelease = { [weak self, weak value] in
                if let value, self?.memberSignInSessions[memberID] === value { self?.memberSignInSessions[memberID] = nil }
            }
            memberSignInSessions[memberID] = value
            return value
        }()
        session.touch()
        return await Self.memberSignIns(method: request.method, path: path, body: request.body, model: session.model)
    }

    /// A member's own view of this Mac's sign-ins: this Mac's device scope and
    /// chat settings (as its own page shows them), and a sign-in that never holds
    /// this Mac's renewal lease, so Pi Durable and bots here keep renewing.
    static func memberSignInModel() -> DefaultAgentSettingsModel {
        let value = DefaultAgentSettingsModel()
        value.holdsSignInLease = false
        value.changeScope("global")
        return value
    }

    static func memberSignIns(method requestMethod: String, path: String, body: Data, model: DefaultAgentSettingsModel) async -> LibraryHTTPResponse {
        guard requestMethod == "POST", servesMemberSignIns(path) else { return .error("not_found", "Unknown sign-in route.", status: 404) }
        do {
            let method: String
            var payload = Data()
            if path == "/v1/connections/command" {
                let command: BackendConnectionsCommand
                do { command = try JSONDecoder().decode(BackendConnectionsCommand.self, from: body).forMember() }
                catch { return .error("invalid_request", "Only this Mac's own sign-ins can be changed here.", status: 400) }
                method = "connections.command"
                payload = try JSONEncoder().encode(command)
            } else { method = "connections.snapshot" }
            let data = try await BackendConnectionsService.handle(method: method, payload: payload, model: model)
            var snapshot = try JSONDecoder().decode(BackendConnectionsSnapshot.self, from: data)
            snapshot.devices = nil
            snapshot.device = nil
            return try .json(snapshot)
        } catch {
            return .error("failed", error.localizedDescription, status: 400)
        }
    }
}

/// One Mac member's sign-in session here. The member polls while a sign-in runs;
/// when it stops (it left the page, slept, went offline) the sign-in is cancelled
/// here after `idleLimit`, so its helper never lingers.
@MainActor final class MemberSignInSession {
    let model: DefaultAgentSettingsModel
    private let idleLimit: Duration
    private let releaseAfter: Duration
    private let clock = ContinuousClock()
    private var lastContact: ContinuousClock.Instant
    private var watchdog: Task<Void, Never>?
    /// Called once the member has been gone `releaseAfter` with nothing running:
    /// the owner drops this session (and its model).
    var onRelease: (@MainActor () -> Void)?

    /// Longer than a member keeps polling through failures (`pollRetryLimit`).
    static let defaultIdleLimit: Duration = .seconds(120)
    static let defaultReleaseAfter: Duration = .seconds(600)
    init(model: DefaultAgentSettingsModel, idleLimit: Duration = MemberSignInSession.defaultIdleLimit,
         releaseAfter: Duration = MemberSignInSession.defaultReleaseAfter) {
        self.model = model; self.idleLimit = idleLimit; self.releaseAfter = releaseAfter; lastContact = clock.now
    }
    deinit { watchdog?.cancel() }

    var isWatching: Bool { watchdog != nil }

    func touch() {
        lastContact = clock.now
        guard watchdog == nil else { return }
        let check = min(idleLimit, releaseAfter, .seconds(5))
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: check)
                guard let self else { return }
                let idle = self.clock.now - self.lastContact
                if self.model.busy || self.model.signInProvider != nil {
                    if idle >= self.idleLimit { self.model.cancel() }
                    continue
                }
                if idle >= self.releaseAfter {
                    self.watchdog = nil
                    self.model.cancel()
                    self.model.stopObserving()
                    self.onRelease?()
                    return
                }
            }
        }
    }
}
