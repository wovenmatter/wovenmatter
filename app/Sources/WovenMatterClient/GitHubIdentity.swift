#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import WovenMatterCore

/// The user's GitHub SSH key and git identity, set once in Settings → GitHub and
/// used by every git command Woven runs: local sessions, the user's other Macs,
/// Linux hosts and bots (docs/architecture/GITHUB_IDENTITY.md).
public struct GitHubSSHKey: Codable, Equatable, Sendable {
    /// OpenSSH private key text, without a passphrase, ending in a newline.
    public var privateKey: String
    /// `<type> <base64>`, without a comment.
    public var publicKey: String
    /// `SHA256:<base64>`, as `ssh-keygen -l` and GitHub show it.
    public var fingerprint: String
    public var comment: String?

    public init(privateKey: String, publicKey: String, fingerprint: String, comment: String?) {
        self.privateKey = privateKey; self.publicKey = publicKey; self.fingerprint = fingerprint; self.comment = comment
    }

    public var type: String { String(publicKey.split(separator: " ").first ?? "") }
    /// The line GitHub's Add SSH key page takes.
    public var authorizedKey: String {
        guard let comment, !comment.isEmpty else { return publicKey }
        return publicKey + " " + comment
    }
    public var summary: GitHubPublicKey { .init(publicKey: authorizedKey, fingerprint: fingerprint, type: type, comment: comment) }
}

/// What Settings shows about the key: never the private key.
public struct GitHubPublicKey: Codable, Equatable, Sendable {
    public var publicKey: String
    public var fingerprint: String
    public var type: String
    public var comment: String?
    public init(publicKey: String, fingerprint: String, type: String, comment: String?) {
        self.publicKey = publicKey; self.fingerprint = fingerprint; self.type = type; self.comment = comment
    }
}

/// Author and committer on every commit. Blank fields keep the machine's own git settings.
public struct GitHubGitIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public init(name: String = "", email: String = "") { self.name = name; self.email = email }
    public var isEmpty: Bool { name.isEmpty && email.isEmpty }

    /// Trimmed, or an error the page shows.
    public func validated() throws -> Self {
        let value = Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                         email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        for field in [value.name, value.email] where field.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw GitHubIdentityError.message("Names and emails cannot contain line breaks or control characters.")
        }
        // UTF-16 lengths, as Linux hosts count them.
        guard value.name.utf16.count <= 200, value.email.utf16.count <= 254 else { throw GitHubIdentityError.message("That name or email is too long.") }
        if !value.email.isEmpty, !value.email.contains("@") || value.email.contains(where: \.isWhitespace) {
            throw GitHubIdentityError.message("Enter an email address, such as the one on your GitHub account.")
        }
        return value
    }
}

/// Which places get the key: Macs and Linux machines by device ID, bots by bot ID. A place
/// the user never switched follows `newPlaces`. The identity goes everywhere; it is not secret.
public struct GitHubAccess: Codable, Equatable, Sendable {
    public var newPlaces: Bool
    /// Lowercased place ID → whether it gets the key.
    public var places: [String: Bool]
    public init(newPlaces: Bool = true, places: [String: Bool] = [:]) {
        self.newPlaces = newPlaces
        self.places = Dictionary(places.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
    }
    public func allows(_ place: String) -> Bool { places[place.lowercased()] ?? newPlaces }
    public mutating func set(_ place: String, _ allowed: Bool) { places[place.lowercased()] = allowed }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(newPlaces: try container.decodeIfPresent(Bool.self, forKey: .newPlaces) ?? true,
                  places: try container.decodeIfPresent([String: Bool].self, forKey: .places) ?? [:])
    }
}

/// The whole setting. `revision` orders changes across Macs (milliseconds; 0 when never set).
public struct GitHubConfiguration: Codable, Equatable, Sendable {
    public var key: GitHubSSHKey?
    public var identity: GitHubGitIdentity
    public var revision: Int64
    public var access: GitHubAccess

    public init(key: GitHubSSHKey? = nil, identity: GitHubGitIdentity = .init(), revision: Int64 = 0, access: GitHubAccess = .init()) {
        self.key = key; self.identity = identity; self.revision = revision; self.access = access
    }
    public var isEmpty: Bool { key == nil && identity.isEmpty }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decodeIfPresent(GitHubSSHKey.self, forKey: .key),
                  identity: try container.decodeIfPresent(GitHubGitIdentity.self, forKey: .identity) ?? .init(),
                  revision: try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0,
                  access: try container.decodeIfPresent(GitHubAccess.self, forKey: .access) ?? .init())
    }
}

/// What a bot's container receives from its machine (`POST /bots-host/git`): the public key
/// while that bot may use the key (it signs through the machine's agent), and the identity.
public struct GitHubBotSetup: Codable, Equatable, Sendable {
    public var publicKey: String?
    public var identity: GitHubGitIdentity?
    public init(publicKey: String? = nil, identity: GitHubGitIdentity? = nil) { self.publicKey = publicKey; self.identity = identity }
    /// What `place` (a bot's ID) gets: the identity always, the public key only while the
    /// machine itself (`machine`, its device ID) and the bot are both on.
    public init(_ configuration: GitHubConfiguration?, place: String, machine: String?) {
        let allowed = configuration.map { $0.access.allows(place) && $0.access.allows(machine ?? "") } ?? false
        publicKey = allowed ? configuration?.key?.authorizedKey : nil
        identity = configuration.flatMap { $0.identity.isEmpty ? nil : $0.identity }
    }
    private enum Keys: String, CodingKey { case publicKey, identity }
    /// Explicit nulls: "nothing set" is a value the receiver applies.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(identity, forKey: .identity)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        identity = try container.decodeIfPresent(GitHubGitIdentity.self, forKey: .identity)
    }
}

/// A Linux host's own copy, opened by its library host for the Woven server (`GET /github`
/// on the library's local socket): the server signs with the key while the host is on.
public struct GitHubHostCopy: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Sendable { public var privateKey: String; public var publicKey: String }
    public var deviceID: String
    public var sshKey: Key?
    public var identity: GitHubGitIdentity?
    public var access: GitHubAccess
    public var revision: Int64
    public init(deviceID: String, configuration: GitHubConfiguration?) {
        self.deviceID = deviceID
        sshKey = configuration?.key.map { .init(privateKey: $0.privateKey, publicKey: $0.authorizedKey) }
        identity = configuration.flatMap { $0.identity.isEmpty ? nil : $0.identity }
        access = configuration?.access ?? .init()
        revision = configuration?.revision ?? 0
    }
    private enum Keys: String, CodingKey { case deviceID, sshKey, identity, access, revision }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(sshKey, forKey: .sshKey)
        try container.encode(identity, forKey: .identity)
        try container.encode(access, forKey: .access)
        try container.encode(revision, forKey: .revision)
    }
}

public enum GitHubIdentityError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

// MARK: - Storage

/// This Mac's copy, in Keychain beside the provider keys (one JSON item).
public enum GitHubConfigurationStore {
    static let account = "github"

    public static func load(keychain: KeychainAccess = .init()) throws -> GitHubConfiguration? {
        guard let text = try DefaultAgentSupport.key(account, keychain: keychain), !text.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode(GitHubConfiguration.self, from: Data(text.utf8)) else {
            throw GitHubIdentityError.message("The saved GitHub settings could not be read. Remove the key and add it again.")
        }
        return value
    }

    /// Saves the item. The background service rewrites this Mac's git files after every change
    /// (`GitHubSettingsModel.writeFiles`), since whether this Mac is on depends on its device ID.
    public static func save(_ value: GitHubConfiguration, keychain: KeychainAccess = .init()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try DefaultAgentSupport.saveKey(String(decoding: try encoder.encode(value), as: UTF8.self), provider: account, notify: false, keychain: keychain)
    }
}

// MARK: - Keys

/// Key generation and checks through the system `ssh-keygen`; nothing is parsed by hand
/// except the public key's fingerprint.
public enum GitHubSSHKeys {
    public static let defaultComment = "woven-matter"
    /// Split so the public-tree secret scan matches only real keys.
    public static let openSSHHeader = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
    public static let openSSHFooter = "-----END OPENSSH " + "PRIVATE KEY-----"
    static let maximumKeyBytes = 16 * 1024

    public static func generate(comment: String = defaultComment) throws -> GitHubSSHKey {
        try withScratch { directory in
            let file = directory.appending(path: "id_ed25519")
            try run(["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", file.path])
            return try inspect(privateKey: String(contentsOf: file, encoding: .utf8), comment: comment)
        }
    }

    /// Checks a pasted private key and derives its public key. Keys with a passphrase are refused:
    /// nobody is at the machine to type it.
    public static func inspect(privateKey text: String, comment: String? = nil) throws -> GitHubSSHKey {
        var privateKey = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !privateKey.isEmpty else { throw GitHubIdentityError.message("Paste a private key.") }
        guard privateKey.utf8.count <= maximumKeyBytes, privateKey.hasPrefix("-----BEGIN "), privateKey.contains("PRIVATE KEY-----") else {
            if privateKey.hasPrefix("ssh-") || privateKey.hasPrefix("ecdsa-") {
                throw GitHubIdentityError.message("That is a public key. Paste the private key, which starts with " + openSSHHeader + ".")
            }
            throw GitHubIdentityError.message("That is not an SSH private key. It starts with " + openSSHHeader + ".")
        }
        privateKey += "\n"
        return try withScratch { directory in
            let file = directory.appending(path: "key")
            try Data(privateKey.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let output: String
            do { output = try run(["-y", "-P", "", "-f", file.path]) }
            catch let GitHubIdentityError.message(detail) {
                if detail.localizedCaseInsensitiveContains("passphrase") {
                    throw GitHubIdentityError.message("This key has a passphrase. Paste a key without one, or generate a new key here.")
                }
                throw GitHubIdentityError.message("That private key could not be read. Paste the whole key, including its BEGIN and END lines.")
            }
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let fingerprint = fingerprint(publicKeyBase64: parts[1]) else {
                throw GitHubIdentityError.message("That private key could not be read.")
            }
            let own = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            // Every machine's signing agent reads one format: OpenSSH's. `-p` rewrites a PEM or
            // PKCS #8 key in it, keeping the same key.
            var saved = privateKey
            if !saved.hasPrefix(openSSHHeader) {
                do { try run(["-p", "-P", "", "-N", "", "-f", file.path]) }
                catch { throw GitHubIdentityError.message("That private key could not be read.") }
                saved = try String(contentsOf: file, encoding: .utf8)
            }
            do { _ = try SSHSigningAgent.parse(privateKey: saved) }
            catch { throw GitHubIdentityError.message("Woven can't sign with this kind of key. Generate one here, or paste an Ed25519, ECDSA, or RSA key.") }
            return GitHubSSHKey(privateKey: saved, publicKey: parts[0] + " " + parts[1], fingerprint: fingerprint, comment: comment ?? own)
        }
    }

    /// `SHA256:` and the unpadded base64 digest of the key blob.
    public static func fingerprint(publicKeyBase64: String) -> String? {
        guard let blob = Data(base64Encoded: publicKeyBase64), !blob.isEmpty else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static var executable: URL? {
        ["/usr/bin/ssh-keygen", "/usr/local/bin/ssh-keygen"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        guard let executable else { throw GitHubIdentityError.message("ssh-keygen is not installed on this machine.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Never prompt: a passphrase request fails at once.
        process.environment = ["PATH": "/usr/bin:/bin", "SSH_ASKPASS": "/usr/bin/false", "SSH_ASKPASS_REQUIRE": "never", "DISPLAY": ""]
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitHubIdentityError.message(String(decoding: err.prefix(2_000), as: UTF8.self))
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-github-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}

// MARK: - Files git and ssh read

/// The files behind the session environment. `ssh_config` and the environment never change,
/// so a session that is already running picks up a new key or identity on its next git command:
///
/// - `ssh_config` includes `github.conf` (only while a key is set), then the user's own
///   `~/.ssh/config` and the system configuration, so other hosts behave as before.
/// - `github.conf` sends github.com this key alone and checks GitHub's published host keys.
/// - `gitconfig` (only while an identity is set) is included at command-line scope.
///
/// Keep the contents identical to `remote/src/github-identity.mjs` and `bots/src/host/git.ts`.
public enum GitHubGitFiles {
    /// GitHub's published SSH host keys (https://api.github.com/meta, `ssh_keys`).
    public static let knownHosts = """
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=

    """

    /// XCTest and swift-testing hosts: they never touch the user's real GitHub folder or socket.
    static let isTestProcess: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath") { return true }
        // `swift test` runs bundles in xctest or swiftpm-testing-helper without those variables.
        if ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName) { return true }
        return Bundle.main.bundleIdentifier?.hasPrefix("com.apple.dt.xctest") == true
    }()

    /// Each Dev profile keeps its own copy, as it keeps its own Keychain items. Tests use a
    /// private temporary folder.
    public static var defaultDirectory: URL {
        if isTestProcess {
            return FileManager.default.temporaryDirectory.appending(path: "woven-github-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        let namespace = WovenMatterKeychainService.current
        let name = namespace == "Woven Matter.desktop" ? "GitHub" : "GitHub " + namespace.dropFirst("Woven Matter.".count)
        return LocalACPManagedRuntimePaths.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// Where this machine's signing agent listens. Darwin limits a socket path to 104 bytes, so a
    /// long support path (a Dev profile's) falls back to the user's private temporary directory.
    public static func agentSocket(in directory: URL) -> URL {
        let socket = directory.appending(path: "agent.sock")
        if socket.path.utf8.count < 100 { return socket }
        let digest = SHA256.hash(data: Data(directory.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appending(path: "woven-github-\(digest).sock")
    }

    /// File name → contents; nil removes the file. `publicKey` is set while this place uses the
    /// key: github.com then asks the agent at `agentSocket`, which holds the private key, and
    /// only the public key is on disk (`IdentityFile` picks it out of the agent).
    public static func contents(publicKey: String?, identity: GitHubGitIdentity?, directory: String, agentSocket: String) -> [String: String?] {
        func quoted(_ path: String) -> String { "\"" + path + "\"" }
        let path = { (name: String) in (directory as NSString).appendingPathComponent(name) }
        var files: [String: String?] = [
            // With a key, github.com gets it alone; every other host keeps the user's own settings.
            "ssh_config": publicKey != nil ? """
            # Written by Woven Matter (Settings → GitHub).
            Include \(quoted(path("github.conf")))
            Match host "!github.com,*"
              Include ~/.ssh/config
              Include /etc/ssh/ssh_config

            """ : """
            # Written by Woven Matter (Settings → GitHub). No key is set: your own SSH settings apply.
            Include ~/.ssh/config
            Include /etc/ssh/ssh_config

            """,
            "known_hosts": knownHosts,
        ]
        if let publicKey {
            files["id_github.pub"] = publicKey + "\n"
            files["github.conf"] = """
            Host github.com
              HostName github.com
              User git
              IdentityAgent \(quoted(agentSocket))
              IdentityFile \(quoted(path("id_github.pub")))
              IdentitiesOnly yes
              UserKnownHostsFile \(quoted(path("known_hosts")))
              StrictHostKeyChecking yes

            """
        } else {
            files["id_github.pub"] = nil as String?
            files["github.conf"] = nil as String?
        }
        var text = ""
        if let identity, !identity.isEmpty {
            text += "[user]\n"
            if !identity.name.isEmpty { text += "\tname = " + gitQuoted(identity.name) + "\n" }
            if !identity.email.isEmpty { text += "\temail = " + gitQuoted(identity.email) + "\n" }
        }
        // With a key, HTTPS remotes on GitHub use it too.
        if publicKey != nil { text += "[url \"git@github.com:\"]\n\tinsteadOf = https://github.com/\n" }
        files["gitconfig"] = text.isEmpty ? nil as String? : text
        return files
    }

    /// ASCII control characters (line breaks included) are dropped, so a value can never
    /// start a new section, whatever a record carried.
    static func gitQuoted(_ value: String) -> String {
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
        return "\"" + kept.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Writes this Mac's files (private, atomically) and removes what no longer applies. `on`
    /// says whether this Mac's agents use the key; the identity applies either way.
    public static func write(_ configuration: GitHubConfiguration?, on: Bool, to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let identity = configuration.flatMap { $0.identity.isEmpty ? nil : $0.identity }
        let files = contents(publicKey: on ? configuration?.key?.authorizedKey : nil, identity: identity,
                             directory: directory.path, agentSocket: agentSocket(in: directory).path)
        for (name, text) in files {
            let url = directory.appending(path: name)
            guard let text else {
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                continue
            }
            let data = Data(text.utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            let temporary = directory.appending(path: "." + name + "." + UUID().uuidString)
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw GitHubIdentityError.message("The GitHub settings could not be saved for git on this Mac.")
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? manager.removeItem(at: temporary)
                throw GitHubIdentityError.message("The GitHub settings could not be saved for git on this Mac.")
            }
        }
    }

    /// Writes the static files when missing, so every session gets the environment below.
    @discardableResult
    public static func install(in directory: URL = defaultDirectory) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appending(path: "ssh_config").path),
           manager.fileExists(atPath: directory.appending(path: "known_hosts").path) { return directory }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["ssh_config", "known_hosts"] {
                guard let text = contents(publicKey: nil, identity: nil, directory: directory.path, agentSocket: "")[name] ?? nil else { continue }
                let url = directory.appending(path: name)
                if !manager.fileExists(atPath: url.path) {
                    guard manager.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
                }
            }
            return directory
        } catch { return nil }
    }

    /// Installed once per process, on first use.
    public static let installedDirectory: URL? = install()

    /// Points git at these files, key or not, so a process started before a key was saved (a
    /// long-running service) uses it as soon as it is; without a key, `ssh_config` holds only the
    /// user's own settings. Never over a `GIT_SSH_COMMAND` or `GIT_SSH` the session already has.
    /// The include is appended to any `GIT_CONFIG_*` entries already present; git ignores it
    /// while there is no identity or key.
    public static func apply(to environment: inout [String: String], directory: String) {
        if environment["GIT_SSH_COMMAND"]?.isEmpty != false, environment["GIT_SSH"]?.isEmpty != false,
           FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("ssh_config")) {
            environment["GIT_SSH_COMMAND"] = "ssh -F " + shellQuoted((directory as NSString).appendingPathComponent("ssh_config"))
        }
        let include = (directory as NSString).appendingPathComponent("gitconfig")
        let count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        if (0..<count).contains(where: { environment["GIT_CONFIG_KEY_\($0)"] == "include.path" && environment["GIT_CONFIG_VALUE_\($0)"] == include }) { return }
        environment["GIT_CONFIG_KEY_\(count)"] = "include.path"
        environment["GIT_CONFIG_VALUE_\(count)"] = include
        environment["GIT_CONFIG_COUNT"] = String(count + 1)
    }

    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
