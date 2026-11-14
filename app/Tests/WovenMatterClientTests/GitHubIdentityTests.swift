import Foundation
import Testing
@testable import WovenMatterClient

/// Settings → GitHub on this machine. Everything runs the local ssh-keygen, ssh -G and git;
/// nothing connects to GitHub.
struct GitHubIdentityTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "woven-github-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path].merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
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

    /// The files written, read back through ssh and git themselves.
    @Test func sshAndGitUseTheKeyForGitHubOnlyAndTheIdentityEverywhere() throws {
        let directory = try Self.scratch().appending(path: "GitHub Files", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let key = try GitHubSSHKeys.generate()
        try GitHubGitFiles.write(.init(key: key, identity: .init(name: "Ada \"The\" Lovelace", email: "ada@example.com"), revision: 1), to: directory)

        for name in ["id_github", "github.conf", "gitconfig", "ssh_config", "known_hosts"] {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600, "\(name) is not private")
        }
        var environment: [String: String] = [:]
        GitHubGitFiles.apply(to: &environment, directory: directory.path)
        let sshCommand = try #require(environment["GIT_SSH_COMMAND"])
        let config = directory.appending(path: "ssh_config").path
        #expect(sshCommand == "ssh -F '" + config + "'")

        let github = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "github.com"])
        #expect(github.status == 0)
        #expect(github.output.contains("identityfile " + directory.appending(path: "id_github").path))
        #expect(github.output.contains("identitiesonly yes"))
        #expect(github.output.contains("stricthostkeychecking true") || github.output.contains("stricthostkeychecking yes"))
        let other = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "example.com"])
        #expect(other.status == 0 && !other.output.contains("id_github"))

        let gitEnvironment = environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        #expect(try Self.run("/usr/bin/git", ["config", "user.name"], environment: gitEnvironment).output == "Ada \"The\" Lovelace\n")
        #expect(try Self.run("/usr/bin/git", ["config", "user.email"], environment: gitEnvironment).output == "ada@example.com\n")

        // Removing the setting leaves ssh and git as they were.
        try GitHubGitFiles.write(nil, to: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "id_github").path))
        let removed = try Self.run("/usr/bin/ssh", ["-G", "-F", config, "github.com"])
        #expect(removed.status == 0 && !removed.output.contains("id_github"))
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
        // Without a saved key the session's own ssh setup stays in charge, GIT_SSH included.
        var plain: [String: String] = [:]
        GitHubGitFiles.apply(to: &plain, directory: directory.path)
        #expect(plain["GIT_SSH_COMMAND"] == nil)
        try GitHubGitFiles.write(.init(key: .init(privateKey: "k", publicKey: "ssh-ed25519 AAAA", fingerprint: "f", comment: nil), revision: 1), to: directory)
        var withGitSSH = ["GIT_SSH": "/usr/bin/my-ssh"]
        GitHubGitFiles.apply(to: &withGitSSH, directory: directory.path)
        #expect(withGitSSH["GIT_SSH_COMMAND"] == nil)
    }

    @Test func identitiesCannotStartANewGitSection() throws {
        let identity = GitHubGitIdentity(name: "Ada\n[core]\n\tsshCommand = evil", email: "a@b")
        let text = try #require(GitHubGitFiles.contents(.init(.init(identity: identity, revision: 1)), directory: "/d")["gitconfig"] ?? nil)
        #expect(text == "[user]\n\tname = \"Ada[core]sshCommand = evil\"\n\temail = \"a@b\"\n")
    }

    @Test func hostsReceiveExplicitNullsWhenNothingIsSet() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(GitHubHostConfiguration(nil)), as: UTF8.self) == #"{"identity":null,"revision":0,"sshKey":null}"#)
        let key = GitHubSSHKey(privateKey: "k", publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:x", comment: "c")
        let value = GitHubHostConfiguration(.init(key: key, identity: .init(), revision: 1))
        #expect(value.sshKey?.publicKey == "ssh-ed25519 AAAA c" && value.identity == nil)
    }
}
