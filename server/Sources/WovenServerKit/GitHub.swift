import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// The GitHub SSH key and git identity on this machine. The key is a synced
/// secret sealed for each machine; the identity and which places use the key
/// are synced settings. Agents never get the key: git reaches it through this
/// server's SSH agent, by files in `github/` in the data folder that every
/// runtime finds through the git settings the server adds to every child's
/// environment (`GitEnvironment`).
actor GitHub {
  static let identityKey = "github.identity"
  static let accessKey = "github.access"

  private let library: Library
  private let secrets: Secrets
  private let folder: URL
  private let agent: SSHAgent
  private let git: GitEnvironment.Settings
  private var key: OpenSSHKey?
  private var watcher: Task<Void, Never>?

  private init(library: Library, secrets: Secrets, folder: URL, agent: SSHAgent) {
    self.library = library
    self.secrets = secrets
    self.folder = folder
    self.agent = agent
    self.git = GitEnvironment.Settings(folder: folder)
  }

  /// Starts the agent, writes the files and points git in every child started
  /// from now on at them. Call before any runtime starts.
  static func start(library: Library, secrets: Secrets, dataFolder: URL) async throws -> GitHub {
    let folder = dataFolder.appendingPathComponent("github", isDirectory: true)
    try GitFiles.makePrivateFolder(folder)
    let socket = try SocketFolder.path("agent.sock", for: dataFolder)
    let agent = try await SSHAgent.start(path: socket)
    let github = GitHub(library: library, secrets: secrets, folder: folder, agent: agent)
    GitEnvironment.use(github.git)
    await github.refresh()
    await github.watch()
    return github
  }

  func stop() async {
    watcher?.cancel()
    await agent.stop()
    GitEnvironment.remove(git)
  }

  /// Follows changes from this machine and others: a new key, identity or switch.
  private func watch() {
    let changes = library.changes()
    watcher = Task { [weak self] in
      for await _ in changes { await self?.refresh() }
    }
  }

  // MARK: State

  private func identity() async -> GitHubIdentity {
    (try? await library.setting(Self.identityKey)?.value.decode(GitHubIdentity.self)) ?? GitHubIdentity()
  }

  private func access() async -> GitHubPlaces {
    (try? await library.setting(Self.accessKey)?.value.decode(GitHubPlaces.self)) ?? GitHubPlaces()
  }

  func state() async -> GitHubState {
    GitHubState(key: key?.summary, identity: await identity(), access: await access())
  }

  /// Reads the key, identity and switch again, and brings the agent and the files in line.
  func refresh() async {
    let stored = try? await secrets.secret(Secrets.gitHubKey)
    key = stored.flatMap { try? OpenSSHKey(text: String(decoding: $0, as: UTF8.self)) }
    let identity = await identity()
    let on = await access().allows(library.machineID)
    agent.use(on ? key : nil)
    try? GitFiles.write(publicKey: on ? key?.summary.publicKey : nil, identity: identity, to: folder, agentSocket: agent.path)
  }

  // MARK: Changes

  func generate() async throws -> GitHubState {
    try await setKey(OpenSSHKey.generate())
  }

  func importKey(_ text: String) async throws -> GitHubState {
    try await setKey(OpenSSHKey(text: text))
  }

  func removeKey() async throws -> GitHubState {
    try await secrets.setSecret(Secrets.gitHubKey, nil)
    await refresh()
    return await state()
  }

  private func setKey(_ key: OpenSSHKey) async throws -> GitHubState {
    try await secrets.setSecret(Secrets.gitHubKey, Data(key.text.utf8))
    await refresh()
    return await state()
  }

  func setIdentity(_ identity: GitHubIdentity) async throws -> GitHubState {
    let value = try Self.validated(identity)
    let json: JSONValue = value.name.isEmpty && value.email.isEmpty ? .null : try JSONValue(encoding: value)
    try await library.setSetting(Self.identityKey, to: json)
    await refresh()
    return await state()
  }

  func setPlace(_ place: String, allowed: Bool) async throws -> GitHubState {
    guard Self.validPlace(place) else { throw ProtocolError(.badRequest, "That place could not be changed.") }
    var access = await access()
    access.places[place.lowercased()] = allowed
    return try await save(access)
  }

  func setNewPlaces(_ allowed: Bool, listed: [String]) async throws -> GitHubState {
    var access = await access()
    // Places already listed keep what they have; only places added later follow the switch.
    for place in listed.prefix(4096) where Self.validPlace(place) && access.places[place.lowercased()] == nil {
      access.places[place.lowercased()] = access.newPlaces
    }
    access.newPlaces = allowed
    return try await save(access)
  }

  private func save(_ access: GitHubPlaces) async throws -> GitHubState {
    try await library.setSetting(Self.accessKey, to: try JSONValue(encoding: access))
    await refresh()
    return await state()
  }

  static func validPlace(_ place: String) -> Bool {
    (1...128).contains(place.utf8.count) && place.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":._-".unicodeScalars.contains($0))
    }
  }

  /// Trimmed, or an error the page shows.
  static func validated(_ identity: GitHubIdentity) throws -> GitHubIdentity {
    let value = GitHubIdentity(name: identity.name.trimmingCharacters(in: .whitespacesAndNewlines),
                               email: identity.email.trimmingCharacters(in: .whitespacesAndNewlines))
    for field in [value.name, value.email] where field.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
      throw ProtocolError(.badRequest, "Names and emails cannot contain line breaks or control characters.")
    }
    guard value.name.utf16.count <= 200, value.email.utf16.count <= 254 else {
      throw ProtocolError(.badRequest, "That name or email is too long.")
    }
    if !value.email.isEmpty, !value.email.contains("@") || value.email.contains(where: \.isWhitespace) {
      throw ProtocolError(.badRequest, "Enter an email address, such as the one on your GitHub account.")
    }
    return value
  }
}

func registerGitHub(_ router: inout Router, github: GitHub) {
  router.on(GetGitHub.self) { _, _ in await github.state() }
  router.on(GenerateGitHubKey.self) { _, _ in try await github.generate() }
  router.on(ImportGitHubKey.self) { request, _ in try await github.importKey(request.privateKey) }
  router.on(RemoveGitHubKey.self) { _, _ in try await github.removeKey() }
  router.on(SetGitHubIdentity.self) { request, _ in try await github.setIdentity(request.identity) }
  router.on(SetGitHubPlace.self) { request, _ in try await github.setPlace(request.place, allowed: request.allowed) }
  router.on(SetGitHubNewPlaces.self) { request, _ in try await github.setNewPlaces(request.allowed, listed: request.listed) }
}

// MARK: Files git and ssh read

/// `ssh_config` includes `github.conf` while the key is on here, then the
/// person's own `~/.ssh/config`, so other hosts behave as before. `github.conf`
/// sends github.com this key alone, through the agent, and checks GitHub's
/// published host keys. `gitconfig` holds the identity and, while the key is
/// on, sends HTTPS GitHub remotes over SSH. Only the public key is on disk.
enum GitFiles {
  /// GitHub's published SSH host keys (https://api.github.com/meta, `ssh_keys`).
  static let knownHosts = """
  github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
  github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=

  """

  static func makePrivateFolder(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
  }

  /// File name to contents; nil removes the file.
  static func contents(publicKey: String?, identity: GitHubIdentity, folder: String, agentSocket: String) -> [String: String?] {
    func quoted(_ path: String) -> String { "\"" + path + "\"" }
    let path = { (name: String) in (folder as NSString).appendingPathComponent(name) }
    var files: [String: String?] = [
      "ssh_config": publicKey != nil ? """
      # Written by Woven Matter (Settings → GitHub).
      Include \(quoted(path("github.conf")))
      Match host "!github.com,*"
        Include ~/.ssh/config
        Include /etc/ssh/ssh_config

      """ : """
      # Written by Woven Matter (Settings → GitHub). No key is on here: your own SSH settings apply.
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
    if !identity.name.isEmpty || !identity.email.isEmpty {
      text += "[user]\n"
      if !identity.name.isEmpty { text += "\tname = " + gitQuoted(identity.name) + "\n" }
      if !identity.email.isEmpty { text += "\temail = " + gitQuoted(identity.email) + "\n" }
    }
    if publicKey != nil { text += "[url \"git@github.com:\"]\n\tinsteadOf = https://github.com/\n" }
    files["gitconfig"] = text.isEmpty ? nil as String? : text
    return files
  }

  /// Control characters are dropped, so a value can never start a new section.
  static func gitQuoted(_ value: String) -> String {
    let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
    return "\"" + kept.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  /// Writes the files privately and in one step each, and removes what no longer applies.
  static func write(publicKey: String?, identity: GitHubIdentity, to folder: URL, agentSocket: String) throws {
    let manager = FileManager.default
    try makePrivateFolder(folder)
    for (name, text) in contents(publicKey: publicKey, identity: identity, folder: folder.path, agentSocket: agentSocket) {
      let url = folder.appendingPathComponent(name)
      guard let text else {
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        continue
      }
      let data = Data(text.utf8)
      if (try? Data(contentsOf: url)) == data { continue }
      let partial = folder.appendingPathComponent("." + name + ".partial")
      guard manager.createFile(atPath: partial.path, contents: data, attributes: [.posixPermissions: 0o600]),
            rename(partial.path, url.path) == 0 else {
        try? manager.removeItem(at: partial)
        throw RuntimeError.failed("Could not save \(url.path).")
      }
    }
  }
}

/// Points git in every child the server starts at the files: `GIT_SSH_COMMAND`
/// (unless the server's own environment sets one) and an include of
/// `gitconfig` at command-line scope. Held here and added to each child's
/// environment as it starts (`ChildProcess.environment`); the server never
/// changes its own, since another thread may be reading it.
enum GitEnvironment {
  struct Settings: Equatable, Sendable {
    var sshCommand: String
    var include: String

    init(folder: URL) {
      sshCommand = "ssh -F " + GitEnvironment.shellQuoted(folder.appendingPathComponent("ssh_config").path)
      include = folder.appendingPathComponent("gitconfig").path
    }
  }

  private static let current = Mutex<Settings?>(nil)

  /// Children started from now on get `settings`.
  static func use(_ settings: Settings) {
    current.withLock { $0 = settings }
  }

  /// Children started from now on no longer get `settings`, unless another
  /// server in this process has put its own in place since.
  static func remove(_ settings: Settings) {
    current.withLock { if $0 == settings { $0 = nil } }
  }

  /// `environment` with the settings in use added.
  static func added(to environment: [String: String]) -> [String: String] {
    added(current.withLock { $0 }, to: environment)
  }

  static func added(_ settings: Settings?, to environment: [String: String]) -> [String: String] {
    guard let settings else { return environment }
    var environment = environment
    if environment["GIT_SSH_COMMAND"]?.isEmpty != false, environment["GIT_SSH"]?.isEmpty != false {
      environment["GIT_SSH_COMMAND"] = settings.sshCommand
    }
    let count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
    if !(0..<count).contains(where: { environment["GIT_CONFIG_KEY_\($0)"] == "include.path" && environment["GIT_CONFIG_VALUE_\($0)"] == settings.include }) {
      environment["GIT_CONFIG_KEY_\(count)"] = "include.path"
      environment["GIT_CONFIG_VALUE_\(count)"] = settings.include
      environment["GIT_CONFIG_COUNT"] = String(count + 1)
    }
    return environment
  }

  static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
