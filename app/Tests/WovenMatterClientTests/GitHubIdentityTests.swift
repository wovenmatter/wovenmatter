import Foundation
import Testing
@testable import WovenMatterClient

/// Settings → GitHub on this machine. Everything runs the local ssh-keygen, ssh-add, ssh -G and
/// git; nothing connects to GitHub.
struct GitHubIdentityTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func scratch() throws -> URL {
        // Short: a Unix socket path must stay under 104 bytes.
        let url = URL(fileURLWithPath: "/tmp").appending(path: "wgh-" + UUID().uuidString.prefix(8), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path].merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func linuxHostsAndBotsWriteTheSameKnownHosts() throws {
        for file in ["remote/src/github-identity.mjs", "bots/src/host/git.ts"] {
            let text = try String(contentsOf: Self.repository.appending(path: file), encoding: .utf8)
            #expect(text.contains("`" + GitHubGitFiles.knownHosts + "`"), "\(file) has different GitHub host keys")
        }
    }

    @Test func generatedKeysAreEd25519WithTheirFingerprint() throws {
        let key = try GitHubSSHKeys.generate()
        #expect(key.type == "ssh-ed25519")
        #expect(key.comment == GitHubSSHKeys.defaultComment)
        #expect(key.authorizedKey.hasSuffix(" " + GitHubSSHKeys.defaultComment))
        #expect(key.privateKey.hasPrefix(GitHubSSHKeys.openSSHHeader) && key.privateKey.hasSuffix("\n"))
        // ssh-keygen agrees on the fingerprint.
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data((key.authorizedKey + "\n").utf8).write(to: directory.appending(path: "key.pub"))
        let listed = try Self.run("/usr/bin/ssh-keygen", ["-l", "-f", directory.appending(path: "key.pub").path])
        #expect(listed.output.contains(key.fingerprint))
        // Pasting the same key back yields the same key.
        let pasted = try GitHubSSHKeys.inspect(privateKey: "\r\n" + key.privateKey.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(pasted.publicKey == key.publicKey && pasted.fingerprint == key.fingerprint && pasted.comment == key.comment)
    }

    /// RSA keys sign only where Apple's Security framework exists; Linux signs Ed25519 and ECDSA.
    static let pemKinds: [[String]] = {
        #if canImport(Security)
        [["rsa", "2048", "RSA"], ["ecdsa", "256", "EC"]]
        #else
        [["ecdsa", "256", "EC"]]
        #endif
    }()

    /// Every machine's agent reads OpenSSH's format, so a PEM key is saved in it, unchanged.
    @Test(arguments: pemKinds)
    func pastedPEMKeysAreSavedInOpenSSHFormat(_ kind: [String]) throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "pem")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", kind[0], "-b", kind[1], "-m", "PEM", "-N", "", "-C", "pem", "-f", file.path])
        let pem = try String(contentsOf: file, encoding: .utf8)
        // Split so the public-tree secret scan matches only real keys.
        #expect(pem.hasPrefix("-----BEGIN \(kind[2]) " + "PRIVATE KEY-----"))
        let key = try GitHubSSHKeys.inspect(privateKey: pem)
        #expect(key.privateKey.hasPrefix(GitHubSSHKeys.openSSHHeader))
        let expected = try String(contentsOf: directory.appending(path: "pem.pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        #expect(key.publicKey == expected)
    }

    #if !canImport(Security)
    /// Without Apple's Security framework an RSA key is refused when it is read, never at signing time.
    @Test func rsaKeysAreRefusedWhereTheyCannotSign() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "key")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-C", "woven-matter", "-f", file.path])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(throws: GitHubIdentityError.message("RSA keys are signed on a Mac.")) { try SSHSigningAgent.parse(privateKey: text) }
        #expect(throws: GitHubIdentityError.self) { try GitHubSSHKeys.inspect(privateKey: text) }
    }
    #endif

    @Test func pastedKeysThatCannotBeUsedAreRefusedWithAReason() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "locked")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "a passphrase", "-C", "locked", "-f", file.path])
        let locked = try String(contentsOf: file, encoding: .utf8)
        #expect(throws: GitHubIdentityError.message("This key has a passphrase. Paste a key without one, or generate a new key here.")) {
            try GitHubSSHKeys.inspect(privateKey: locked)
        }
        let publicKey = try String(contentsOf: directory.appending(path: "locked.pub"), encoding: .utf8)
        #expect(throws: GitHubIdentityError.self) { try GitHubSSHKeys.inspect(privateKey: publicKey) }
        #expect(throws: GitHubIdentityError.self) { try GitHubSSHKeys.inspect(privateKey: "hello") }
        #expect(throws: GitHubIdentityError.self) {
            try GitHubSSHKeys.inspect(privateKey: GitHubSSHKeys.openSSHHeader + "\nnot a key\n" + GitHubSSHKeys.openSSHFooter)
        }
    }

    @Test func identitiesAreCheckedBeforeSaving() throws {
        #expect(try GitHubGitIdentity(name: "  Ada Lovelace ", email: " ada@example.com\n").validated() == .init(name: "Ada Lovelace", email: "ada@example.com"))
        #expect(try GitHubGitIdentity().validated().isEmpty)
        #expect(throws: GitHubIdentityError.self) { try GitHubGitIdentity(name: "Ada\nEvil", email: "").validated() }
        #expect(throws: GitHubIdentityError.self) { try GitHubGitIdentity(name: "Ada", email: "not an email").validated() }
    }

    /// The agent signs with every kind of key it accepts, through its socket, as ssh asks it,
    /// and refuses the moment the place is turned off. The key file itself is never on disk.
    static let signingKinds: [[String]] = {
        let portable: [[String]] = [["ed25519"], ["ecdsa", "256"], ["ecdsa", "384"], ["ecdsa", "521"]]
        #if canImport(Security)
        return portable + [["rsa", "2048"]]
        #else
        return portable
        #endif
    }()

    @Test(arguments: signingKinds)
    func sshSignsThroughTheAgentWithAKeyItNeverSees(_ kind: [String]) throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "key")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", kind[0]] + (kind.count > 1 ? ["-b", kind[1]] : []) + ["-N", "", "-C", "woven-matter", "-f", file.path])
        let key = try SSHSigningAgent.parse(privateKey: String(contentsOf: file, encoding: .utf8))
        try FileManager.default.removeItem(at: file)
        let allowed = Allowed()
        let socket = directory.appending(path: "agent.sock")
        let server = SSHAgentSocketServer(socketURL: socket) { SSHSigningAgent.reply(to: $0, key: allowed.on ? key : nil) }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let environment = ["SSH_AUTH_SOCK": socket.path]
        let publicKey = try String(contentsOf: directory.appending(path: "key.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try Self.run("/usr/bin/ssh-add", ["-L"], environment: environment).output.trimmingCharacters(in: .whitespacesAndNewlines) == publicKey)

        let message = directory.appending(path: "message")
        try Data("hello".utf8).write(to: message)
        let signed = try Self.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", directory.appending(path: "key.pub").path, "-n", "git", message.path], environment: environment)
        #expect(signed.status == 0, "\(signed.output)")
        let checked = try Self.run("/usr/bin/ssh-keygen", ["-Y", "check-novalidate", "-n", "git", "-f", directory.appending(path: "key.pub").path,
                                                           "-s", message.path + ".sig"], input: "hello")
        #expect(checked.status == 0, "\(checked.output)")

        allowed.on = false
        try? FileManager.default.removeItem(atPath: message.path + ".sig")
        #expect(try Self.run("/usr/bin/ssh-add", ["-L"], environment: environment).status != 0)
        #expect(try Self.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", directory.appending(path: "key.pub").path, "-n", "git", message.path], environment: environment).status != 0)
    }

    final class Allowed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    @Test func malformedAgentRequestsAreRefused() {
        #expect(SSHSigningAgent.reply(to: Data(), key: nil) == Data([5]))
        #expect(SSHSigningAgent.reply(to: Data([17]), key: nil) == Data([5]))
        #expect(SSHSigningAgent.reply(to: Data([13, 0, 0]), key: nil) == Data([5]))
        #expect(SSHSigningAgent.reply(to: Data([11]), key: nil) == Data([12, 0, 0, 0, 0]))
    }

    /// The files written, read back through ssh and git themselves.
    @Test func sshAndGitUseTheAgentForGitHubOnlyAndTheIdentityEverywhere() throws {
        let directory = try Self.scratch().appending(path: "GitHub Files", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let key = try GitHubSSHKeys.generate()
        let setting = GitHubConfiguration(key: key, identity: .init(name: "Ada \"The\" Lovelace", email: "ada@example.com"), revision: 1)
        try GitHubGitFiles.write(setting, on: true, to: directory)

        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "id_github").path))
        for name in ["id_github.pub", "github.conf", "gitconfig", "ssh_config", "known_hosts"] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600, "\(name) is not private")
        }
        var environment: [String: String] = [:]
        GitHubGitFiles.apply(to: &environment, directory: directory.path)
        let config = directory.appending(path: "ssh_config").path
        #expect(environment["GIT_SSH_COMMAND"] == "ssh -F '" + config + "'")

        let github = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "github.com"])
        #expect(github.status == 0)
        #expect(github.output.contains("identityagent " + GitHubGitFiles.agentSocket(in: directory).path))
        #expect(github.output.contains("identityfile " + directory.appending(path: "id_github.pub").path))
        #expect(github.output.contains("identitiesonly yes"))
        #expect(github.output.contains("stricthostkeychecking true") || github.output.contains("stricthostkeychecking yes"))
        let other = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "example.com"])
        #expect(other.status == 0 && !other.output.contains("id_github") && !other.output.contains("agent.sock"))

        let gitEnvironment = environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        #expect(try Self.run("/usr/bin/git", ["config", "user.name"], environment: gitEnvironment).output == "Ada \"The\" Lovelace\n")
        #expect(try Self.run("/usr/bin/git", ["config", "user.email"], environment: gitEnvironment).output == "ada@example.com\n")
        // HTTPS remotes on GitHub use the key too; other hosts are left alone.
        #expect(try Self.run("/usr/bin/git", ["ls-remote", "--get-url", "https://github.com/o/r.git"], environment: gitEnvironment).output == "git@github.com:o/r.git\n")
        #expect(try Self.run("/usr/bin/git", ["ls-remote", "--get-url", "https://example.com/o/r.git"], environment: gitEnvironment).output == "https://example.com/o/r.git\n")

        // This Mac turned off: the identity stays, github.com goes back to the user's own settings.
        try GitHubGitFiles.write(setting, on: false, to: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "id_github.pub").path))
        let off = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "github.com"])
        #expect(off.status == 0 && !off.output.contains("agent.sock"))
        #expect(try Self.run("/usr/bin/git", ["config", "user.name"], environment: gitEnvironment).output == "Ada \"The\" Lovelace\n")
        // Removing the setting leaves ssh and git as they were.
        try GitHubGitFiles.write(nil, on: false, to: directory)
        #expect(try Self.run("/usr/bin/git", ["config", "user.name"], environment: gitEnvironment).status != 0)
    }

    @Test func theEnvironmentKeepsWhatTheSessionAlreadySet() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ["GIT_SSH_COMMAND": "ssh -i mine", "GIT_CONFIG_COUNT": "1",
                           "GIT_CONFIG_KEY_0": "core.editor", "GIT_CONFIG_VALUE_0": "vi"]
        GitHubGitFiles.apply(to: &environment, directory: directory.path)
        GitHubGitFiles.apply(to: &environment, directory: directory.path)
        #expect(environment["GIT_SSH_COMMAND"] == "ssh -i mine")
        #expect(environment["GIT_CONFIG_COUNT"] == "2")
        #expect(environment["GIT_CONFIG_KEY_0"] == "core.editor")
        #expect(environment["GIT_CONFIG_KEY_1"] == "include.path" && environment["GIT_CONFIG_VALUE_1"] == directory.appending(path: "gitconfig").path)
        // Before the files exist nothing points at them; once they do, ssh does, key or not, so a
        // process started before a key was saved uses it as soon as it is. GIT_SSH stays in charge.
        var plain: [String: String] = [:]
        GitHubGitFiles.apply(to: &plain, directory: directory.path)
        #expect(plain["GIT_SSH_COMMAND"] == nil)
        try GitHubGitFiles.write(nil, on: false, to: directory)
        GitHubGitFiles.apply(to: &plain, directory: directory.path)
        #expect(plain["GIT_SSH_COMMAND"] == "ssh -F '" + directory.appending(path: "ssh_config").path + "'")
        var withGitSSH = ["GIT_SSH": "/usr/bin/my-ssh"]
        GitHubGitFiles.apply(to: &withGitSSH, directory: directory.path)
        #expect(withGitSSH["GIT_SSH_COMMAND"] == nil)
    }

    @Test func identitiesCannotStartANewGitSection() throws {
        let identity = GitHubGitIdentity(name: "Ada\n[core]\n\tsshCommand = evil", email: "a@b")
        let text = try #require(GitHubGitFiles.contents(publicKey: nil, identity: identity, directory: "/d", agentSocket: "/d/agent.sock")["gitconfig"] ?? nil)
        #expect(text == "[user]\n\tname = \"Ada[core]sshCommand = evil\"\n\temail = \"a@b\"\n")
    }

    /// The Mac writes exactly what Linux hosts and bot containers write.
    @Test func linuxHostsAndBotsWriteTheSameFiles() throws {
        let source = try String(contentsOf: Self.repository.appending(path: "remote/src/github-identity.mjs"), encoding: .utf8)
        let files = GitHubGitFiles.contents(publicKey: "ssh-ed25519 AAAA k", identity: .init(name: "Ada"), directory: "/d", agentSocket: "/d/agent.sock")
        let conf = try #require(files["github.conf"] ?? nil)
        #expect(conf.contains("  IdentityAgent \"/d/agent.sock\"\n  IdentityFile \"/d/id_github.pub\"\n"))
        #expect(source.contains("  IdentityAgent ${quoted(agentSocket)}\n  IdentityFile ${quoted(join(directory, 'id_github.pub'))}\n"))
        #expect(files["gitconfig"] == "[user]\n\tname = \"Ada\"\n[url \"git@github.com:\"]\n\tinsteadOf = https://github.com/\n")
    }

    /// A bot gets the public key only while its machine and the bot itself are both on.
    @Test func botsGetThePublicKeyOnlyWhileOn() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(GitHubBotSetup()), as: UTF8.self) == #"{"identity":null,"publicKey":null}"#)
        let key = GitHubSSHKey(privateKey: "k", publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:x", comment: "c")
        var setting = GitHubConfiguration(key: key, identity: .init(name: "Ada"), revision: 3)
        #expect(GitHubBotSetup(setting, place: "bot-1", machine: "mac-1").publicKey == "ssh-ed25519 AAAA c")
        setting.access.set("BOT-1", false)
        #expect(GitHubBotSetup(setting, place: "bot-1", machine: "mac-1").publicKey == nil)
        #expect(GitHubBotSetup(setting, place: "bot-1", machine: "mac-1").identity?.name == "Ada")
        setting.access.set("bot-1", true)
        setting.access.set("mac-1", false)
        #expect(GitHubBotSetup(setting, place: "bot-1", machine: "mac-1").publicKey == nil)
        setting.access = .init(newPlaces: false, places: ["mac-1": true])
        #expect(GitHubBotSetup(setting, place: "bot-2", machine: "mac-1").publicKey == nil)
        // A copy saved before the list existed reads as "everywhere".
        let old = try JSONDecoder().decode(GitHubConfiguration.self, from: Data(#"{"identity":{"name":"","email":""},"revision":2}"#.utf8))
        #expect(old.access == GitHubAccess() && old.access.allows("anything"))
    }

    /// Darwin's 104-byte socket path limit: a long support path falls back to a short one.
    @Test func theAgentSocketPathFitsDarwinsLimit() {
        let short = URL(fileURLWithPath: "/var/home/Library/Application Support/Woven Matter/GitHub")
        #expect(GitHubGitFiles.agentSocket(in: short) == short.appending(path: "agent.sock"))
        let long = URL(fileURLWithPath: "/var/home/an-account-name/Library/Application Support/Woven Matter Dev/a-long-instance-name/snapshot/GitHub desktop.dev.instance")
        let socket = GitHubGitFiles.agentSocket(in: long)
        #expect(socket.path.utf8.count < 104 && socket.lastPathComponent.hasPrefix("woven-github-"))
        #expect(GitHubGitFiles.agentSocket(in: long) == socket)
    }
}
