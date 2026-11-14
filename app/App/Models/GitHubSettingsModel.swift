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
}

/// Requests travel only over the private local backend transport. Never log
/// payloads: `importKey` carries a private key.
struct GitHubSettingsCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case generate, importKey, removeKey, saveIdentity }
    var action: Action
    var privateKey: String? = nil
    var identity: GitHubGitIdentity? = nil
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
        switch command.action {
        case .generate:
            let key = try await Task.detached { try GitHubSSHKeys.generate() }.value
            update = { $0.key = key }
        case .importKey:
            let text = command.privateKey ?? ""
            let key = try await Task.detached { try GitHubSSHKeys.inspect(privateKey: text) }.value
            update = { $0.key = key }
        case .removeKey:
            update = { $0.key = nil }
        case .saveIdentity:
            let identity = try (command.identity ?? .init()).validated()
            update = { $0.identity = identity }
        }
        if let sync = await resolveSync() {
            _ = try await sync.change(update)
        } else {
            // No library yet: this Mac alone; the next reconcile shares it.
            var value = (try? GitHubConfigurationStore.load()).flatMap { $0 } ?? .init()
            try update(&value)
            value.revision = max(Int64(Date().timeIntervalSince1970 * 1000), value.revision + 1)
            try GitHubConfigurationStore.save(value)
        }
    }

    private func currentSnapshot() async throws -> GitHubSettingsSnapshot {
        let value: GitHubConfiguration?
        do { value = try GitHubConfigurationStore.load() }
        catch is GitHubIdentityError { value = nil } // Unreadable: shown as nothing set, so it can be replaced.
        return .init(key: value?.key?.summary, identity: value?.identity ?? .init(),
                     waitingForAnotherMac: await resolveSync()?.waitingForCopy() ?? false)
    }

    private func resolveSync() async -> GitHubIdentitySync? { sync }

    func attach(_ sync: GitHubIdentitySync) { self.sync = sync }

    /// After launch and whenever peers sync: take a newer setting from another Mac,
    /// share this one, or seal copies for Macs that joined since.
    func reconcile() async {
        if !materialized {
            materialized = true
            // The files follow Keychain, even if something removed them.
            try? GitHubGitFiles.write(try GitHubConfigurationStore.load(), to: GitHubGitFiles.defaultDirectory)
        }
        guard let sync = await resolveSync() else { return }
        do {
            if try await sync.reconcile() { snapshot = try await currentSnapshot() }
        } catch { self.error = error.localizedDescription }
    }
}
