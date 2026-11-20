import Foundation
import WovenProtocol

/// Settings → GitHub: this Mac's server holds the key and answers with the
/// public key only. Never log a command: `importKey` carries a private key.
extension SettingsStore {
    func loadGitHub() async {
        guard let server else {
            githubError = ClientError.notConnected.localizedDescription
            return
        }
        do {
            github = GitHubSettings(try await server.call(GetGitHub()))
            githubError = nil
        } catch {
            githubError = Self.gitHubMessage(error)
        }
    }

    /// True when the command succeeded.
    @discardableResult
    func runGitHub(_ command: GitHubSettingsCommand) async -> Bool {
        guard !githubBusy else { return false }
        guard let server else {
            githubError = ClientError.notConnected.localizedDescription
            return false
        }
        githubBusy = true
        githubError = nil
        defer { githubBusy = false }
        do {
            let state: GitHubState = switch command {
            case .generate: try await server.call(GenerateGitHubKey())
            case .importKey(let privateKey): try await server.call(ImportGitHubKey(privateKey: privateKey))
            case .removeKey: try await server.call(RemoveGitHubKey())
            case .saveIdentity(let identity):
                try await server.call(SetGitHubIdentity(identity: GitHubIdentity(name: identity.name, email: identity.email)))
            case .setPlace(let place, let allowed): try await server.call(SetGitHubPlace(place: place, allowed: allowed))
            case .setNewPlaces(let allowed, let listed): try await server.call(SetGitHubNewPlaces(allowed: allowed, listed: listed))
            }
            github = GitHubSettings(state)
            return true
        } catch {
            githubError = Self.gitHubMessage(error)
            return false
        }
    }

    private static func gitHubMessage(_ error: any Error) -> String {
        (error as? ProtocolError)?.message ?? error.localizedDescription
    }
}

private extension GitHubSettings {
    init(_ state: GitHubState) {
        self.init(key: state.key.map { GitHubPublicKey(publicKey: $0.publicKey, fingerprint: $0.fingerprint, type: $0.type, comment: $0.comment) },
                  identity: GitHubGitIdentity(name: state.identity.name, email: state.identity.email),
                  access: GitHubAccess(newPlaces: state.access.newPlaces, places: state.access.places))
    }
}
