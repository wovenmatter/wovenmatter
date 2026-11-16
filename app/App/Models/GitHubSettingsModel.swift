import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// What Settings → GitHub shows. Never the private key.
struct GitHubSettingsSnapshot: Codable, Equatable, Sendable {
    var key: GitHubPublicKey?
    var identity = GitHubGitIdentity()
    /// Another Mac changed the key and has not sealed a copy to this one yet.
    var waitingForAnotherMac = false
    var access = GitHubAccess()
    /// This Mac's device ID, the place listed as This Mac.
    var thisDeviceID: String?
}

/// Requests travel only over the private local backend transport. Never log
/// payloads: `importKey` carries a private key.
struct GitHubSettingsCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case generate, importKey, removeKey, saveIdentity, setPlace, setNewPlaces }
    var action: Action
    var privateKey: String? = nil
    var identity: GitHubGitIdentity? = nil
    /// `setPlace`: a machine's device ID or a bot's ID.
    var place: String? = nil
    var allowed: Bool? = nil
    /// `setNewPlaces`: the places Settings lists, which keep what they have now.
    var listed: [String]? = nil
}

/// The key the signing agent answers with, and who may use it. Read from any thread: the
/// agent's socket and bot requests arrive off the main actor.
final class GitHubAgentState: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: GitHubConfiguration?
    private var key: SSHSigningAgent.Key?
    private var thisDeviceID: String?

    func update(_ configuration: GitHubConfiguration?, thisDeviceID: String?) {
        let parsed = configuration?.key.flatMap { try? SSHSigningAgent.parse(privateKey: $0.privateKey) }
        lock.withLock { self.configuration = configuration; key = parsed; self.thisDeviceID = thisDeviceID }
    }

    /// Whether this Mac's agents use the key (a Mac without a library at all follows New places).
    static func on(_ configuration: GitHubConfiguration?, thisDeviceID: String?) -> Bool {
        configuration.map { $0.key != nil && $0.access.allows(thisDeviceID ?? "") } ?? false
    }

    /// A session on this Mac: the key while this Mac is on.
    func sessionReply(_ message: Data) -> Data {
        let key = lock.withLock { Self.on(configuration, thisDeviceID: thisDeviceID) ? self.key : nil }
        return SSHSigningAgent.reply(to: message, key: key)
    }

    /// A bot on this Mac: the key while this Mac and the bot are both on.
    func botReply(_ message: Data, botID: String) -> Data {
        let key = lock.withLock { () -> SSHSigningAgent.Key? in
            guard Self.on(configuration, thisDeviceID: thisDeviceID), configuration?.access.allows(botID) == true else { return nil }
            return self.key
        }
        return SSHSigningAgent.reply(to: message, key: key)
    }

    func botSetup(_ botID: String) -> GitHubBotSetup {
        lock.withLock { GitHubBotSetup(configuration, place: botID, machine: thisDeviceID) }
    }
}

/// Settings → GitHub. The background service owns the Keychain item and the
/// shared library record (docs/architecture/GITHUB_IDENTITY.md); this window
/// forwards commands to it and shows the snapshot it answers.
@MainActor @Observable
final class GitHubSettingsModel {
    private(set) var snapshot: GitHubSettingsSnapshot?
    private(set) var busy = false
    var error: String?

    @ObservationIgnored var backendRequest: ((String, Data) async throws -> Data)?
    /// The background service's sync with the user's other Macs, once the library is open.
    @ObservationIgnored private var sync: GitHubIdentitySync?
    @ObservationIgnored private var materialized = false

    func load() async {
        do { snapshot = try await call(nil) }
        catch { self.error = error.localizedDescription }
    }

    /// True when the command succeeded.
    @discardableResult
    func run(_ command: GitHubSettingsCommand) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await call(command)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func call(_ command: GitHubSettingsCommand?) async throws -> GitHubSettingsSnapshot {
        if let backendRequest {
            let data = try await backendRequest(command == nil ? "github.snapshot" : "github.command",
                                                command.map { try JSONEncoder().encode($0) } ?? Data())
            return try JSONDecoder().decode(GitHubSettingsSnapshot.self, from: data)
        }
        guard LocalExecutionRole.current != .frontend else {
            throw GitHubIdentityError.message("The background service is not connected.")
        }
        if let command { try await perform(command) }
        return try await currentSnapshot()
    }

    // MARK: Background service

    func handle(method: String, payload: Data) async throws -> Data {
        switch method {
        case "github.snapshot": break
        case "github.command":
            guard payload.count <= 65_536 else { throw BackendRPCError.invalidFrame }
            try await perform(JSONDecoder().decode(GitHubSettingsCommand.self, from: payload))
        default: throw CocoaError(.featureUnsupported)
        }
        return try JSONEncoder().encode(await currentSnapshot())
    }

    private func perform(_ command: GitHubSettingsCommand) async throws {
        let update: @Sendable (inout GitHubConfiguration) throws -> Void
        var replacesKey = false
        switch command.action {
        case .generate:
            let key = try await Task.detached { try GitHubSSHKeys.generate() }.value
            update = { $0.key = key }; replacesKey = true
        case .importKey:
            let text = command.privateKey ?? ""
            let key = try await Task.detached { try GitHubSSHKeys.inspect(privateKey: text) }.value
            update = { $0.key = key }; replacesKey = true
        case .removeKey:
            update = { $0.key = nil }; replacesKey = true
        case .saveIdentity:
            let identity = try (command.identity ?? .init()).validated()
            update = { $0.identity = identity }
        case .setPlace:
            guard let place = command.place, Self.validPlace(place), let allowed = command.allowed else {
                throw GitHubIdentityError.message("That place could not be changed.")
            }
            update = { $0.access.set(place, allowed) }
        case .setNewPlaces:
            guard let allowed = command.allowed else { throw GitHubIdentityError.message("That setting could not be changed.") }
            let listed = (command.listed ?? []).filter(Self.validPlace).prefix(4096)
            update = { value in
                // Places already listed keep what they have; only places added later follow the switch.
                for place in listed where value.access.places[place.lowercased()] == nil {
                    value.access.set(place, value.access.newPlaces)
                }
                value.access.newPlaces = allowed
            }
        }
        if let sync = await resolveSync() {
            _ = try await sync.change(replacesKey: replacesKey, update)
        } else {
            // No library yet: this Mac alone; the next reconcile shares it.
            var value = (try? GitHubConfigurationStore.load()).flatMap { $0 } ?? .init()
            try update(&value)
            value.revision = max(Int64(Date().timeIntervalSince1970 * 1000), value.revision + 1)
            try GitHubConfigurationStore.save(value)
        }
        await refreshAgent()
    }

    static func validPlace(_ place: String) -> Bool {
        (1...128).contains(place.utf8.count) && place.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || ":._-".unicodeScalars.contains($0)
        }
    }

    private func currentSnapshot() async throws -> GitHubSettingsSnapshot {
        let value: GitHubConfiguration?
        do { value = try GitHubConfigurationStore.load() }
        catch is GitHubIdentityError { value = nil } // Unreadable: shown as nothing set, so it can be replaced.
        return .init(key: value?.key?.summary, identity: value?.identity ?? .init(),
                     waitingForAnotherMac: await resolveSync()?.waitingForCopy() ?? false,
                     access: value?.access ?? .init(), thisDeviceID: await thisDeviceID())
    }

    private func resolveSync() async -> GitHubIdentitySync? { sync }

    /// This Mac's member device ID, its place in the list. It comes from the library itself, so
    /// whether This Mac is on never waits for peer sync (or sharing) to start.
    @ObservationIgnored var localDeviceID: (@MainActor () async -> String?)?
    private func thisDeviceID() async -> String? {
        if let id = await resolveSync()?.deviceID { return id }
        return await localDeviceID?()
    }

    func attach(_ sync: GitHubIdentitySync) { self.sync = sync }

    /// After launch and whenever peers sync: take a newer setting from another Mac,
    /// share this one, or seal copies for machines that joined since.
    func reconcile() async {
        if !materialized {
            materialized = true
            // The files and the agent follow Keychain, even if something removed the files.
            await refreshAgent()
        }
        guard let sync = await resolveSync() else { return }
        do {
            if try await sync.reconcile() {
                snapshot = try await currentSnapshot()
                await refreshAgent()
            }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Signing agent

    /// What the agent signs with; bots on this Mac ask through `botReply`.
    let agentState = GitHubAgentState()
    @ObservationIgnored private var agent: SSHAgentSocketServer?
    @ObservationIgnored private var agentLoop: Task<Void, Never>?

    /// Starts this Mac's signing agent (the process that owns execution). The socket can sit in
    /// a temporary directory the system cleans, so it is checked again every minute.
    func startAgent() {
        guard agentLoop == nil else { return }
        let state = agentState
        let server = SSHAgentSocketServer(socketURL: GitHubGitFiles.agentSocket(in: GitHubGitFiles.defaultDirectory)) { state.sessionReply($0) }
        agent = server
        agentLoop = Task { [weak self] in
            await self?.refreshAgent()
            while !Task.isCancelled {
                if !server.isRunning { server.stop(); try? server.start() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Rewrites this Mac's files and the agent's key after any change, here or from another Mac.
    func refreshAgent() async {
        let value: GitHubConfiguration?
        do { value = try GitHubConfigurationStore.load() } catch is GitHubIdentityError { value = nil } catch { return }
        let thisDeviceID = await thisDeviceID()
        agentState.update(value, thisDeviceID: thisDeviceID)
        try? GitHubGitFiles.write(value, on: GitHubAgentState.on(value, thisDeviceID: thisDeviceID), to: GitHubGitFiles.defaultDirectory)
    }
}
