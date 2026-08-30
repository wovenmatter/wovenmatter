import Foundation
import Testing
@testable import WovenMatterClient
@testable import WovenMatterCore

@Suite("Runtime boundaries", .serialized)
struct RuntimeBoundaryTests {
  @Test("local and remote initializers produce the same workspace")
  func workspaceLayout() throws {
    let fixture = try TemporaryDirectory(prefix: "wovenmatter-layout")
    defer { fixture.remove() }
    let local = fixture.url.appending(path: "local", directoryHint: .isDirectory)
    let remote = fixture.url.appending(path: "remote", directoryHint: .isDirectory)

    _ = try LocalACPWorkspaceProvisioner.ensureWorkspace(at: local, repositoriesURL: nil)
    let initializer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "../harnesses/initialize-workspace.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [initializer.path, remote.path]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(try entries(at: local) == entries(at: remote))
    #expect(try FileManager.default.destinationOfSymbolicLink(
      atPath: local.appending(path: "CLAUDE.md").path
    ) == "AGENTS.md")
  }

  @Test("local workspace folder preferences persist outside Keychain")
  func workspaceFolderPreferences() async throws {
    let fixture = try TemporaryDirectory(prefix: "wovenmatter-workspace-preferences")
    defer { fixture.remove() }
    let repositories = fixture.url.appending(
      path: "repositories",
      directoryHint: .isDirectory
    )
    let databases = fixture.url.appending(
      path: "databases",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: repositories,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: databases,
      withIntermediateDirectories: true
    )
    let suiteName = "wovenmatter.workspace-preferences.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let service = "Woven Matter.test.\(UUID().uuidString)"
    let store = LocalACPWorkspaceConfigurationStore(
      homeDirectory: fixture.url,
      defaultsSuiteName: suiteName,
      storageKey: service
    )

    try await store.configureRepositories(repositories)
    try await store.configureDatabases(databases)

    let restored = LocalACPWorkspaceConfigurationStore(
      homeDirectory: fixture.url,
      defaultsSuiteName: suiteName,
      storageKey: service
    )
    let resolution = await restored.resolve()
    #expect(resolution.availability.repositoriesPath == repositories.path)
    #expect(resolution.availability.databasesPath == databases.path)
    #expect(resolution.availability.usesExternalRepositories)
    #expect(resolution.availability.usesExternalDatabases)
  }

  @Test("a fake ACP process completes one streamed turn")
  func acpRoundTrip() async throws {
    let fixture = try FakeACPProcess()
    defer { fixture.remove() }
    let events = EventCollector()
    let client = try LocalACPClient.start(
      launch: LocalACPRuntimeLaunchConfiguration(
        runtimeKind: .codex,
        executableURL: fixture.executable,
        arguments: []
      ),
      workingDirectory: fixture.directory
    )

    let session = try await client.initializeSession(
      workingDirectory: fixture.directory,
      existingSessionID: nil,
      title: "Fake ACP"
    )
    #expect(session.sessionID == "fake-session")
    #expect(try await client.prompt("Hello") { event in
      await events.record(event)
    } == .endTurn)
    await client.shutdown()
    #expect(await events.text() == "Hello from fake ACP")
  }

  @Test("remote commands preserve data and reject unsafe input")
  func remoteWorkspaceBoundary() async throws {
    let recorder = SSHRecorder(response: Self.statusJSON)
    let client = RemoteWorkspaceSSHClient(
      runner: { destination, command, input in
        try recorder.record(destination: destination, command: command, input: input)
      },
      scriptLoader: { Data("script".utf8) }
    )
    let configuration = RemoteWorkspaceConfiguration(
      name: "Work",
      workspaceID: "work-1",
      hostName: "linux-box",
      userName: "woven",
      remotePort: 7440,
      memoryLimit: "8",
      swapLimit: "4"
    )

    _ = try await client.create(configuration: configuration, token: "secret-token")
    #expect(recorder.destination == "woven@linux-box")
    #expect(recorder.command?.contains("secret-token") == false)
    #expect(recorder.command?.contains("'8589934592' '12884901888'") == true)
    #expect(recorder.input?.starts(with: Data("secret-token\nscript".utf8)) == true)

    let launch = try RemoteHarnessLaunchResolver.resolve(
      configuration: configuration,
      runtimeKind: .codex,
      processWorkingDirectory: URL(filePath: "/private/tmp")
    )
    #expect(launch.workspace.rootURL.path == "/home/.woven-matter")
    #expect(launch.launch.arguments.last?.contains("'HOME=/home'") == true)

    let deleteRecorder = SSHRecorder(response: #"{"deleted":true}"#)
    let deleteClient = RemoteWorkspaceSSHClient(
      runner: { destination, command, input in
        try deleteRecorder.record(destination: destination, command: command, input: input)
      },
      scriptLoader: { Data("script".utf8) }
    )
    try await deleteClient.delete(configuration: configuration, removePersistentData: false)
    #expect(deleteRecorder.command == "exec bash -s -- 'delete' 'work-1'")
    try await deleteClient.delete(configuration: configuration, removePersistentData: true)
    #expect(deleteRecorder.command == "exec bash -s -- 'delete' 'work-1' '--data'")

    #expect(throws: RemoteWorkspaceClientError.self) {
      try RemoteWorkspaceSSHClient.validatedDestination(
        hostName: "-oProxyCommand=bad",
        userName: nil
      )
    }
  }

  @Test("OpenClaw Gateway hello parsing enforces the protocol")
  func gatewayProtocol() throws {
    let capabilities = try OpenClawGatewayClient.capabilities(from: .object([
      "protocol": .number(4),
      "server": .object(["version": .string("test")]),
      "features": .object([
        "methods": .array([.string("sessions.patch")]),
        "events": .array([.string("chat")]),
      ]),
      "policy": .object(["maxPayload": .number(12_000_000)]),
    ]))
    #expect(capabilities.applicationVersion == "test")
    #expect(capabilities.supports("sessions.patch"))
    #expect(throws: OpenClawGatewayClientError.malformedFrame) {
      _ = try OpenClawGatewayClient.capabilities(from: .object([:]))
    }

    let token = "remote-gateway-token"
    let signedAt = 1_772_000_123_456
    #expect(OpenClawGatewayClient.bearerToken(from: [
      "authorization": "Bearer \(token)",
    ]) == token)
    #expect(OpenClawGatewayClient.deviceSignaturePayload(
      deviceID: "device",
      scopes: ["operator.read"],
      signedAt: signedAt,
      token: token,
      nonce: "challenge"
    ).contains("|\(signedAt)|\(token)|challenge|"))
    let parameters = OpenClawGatewayClient.connectParameters(
      deviceID: "device",
      publicKey: "public-key",
      signature: "signature",
      signedAt: signedAt,
      nonce: "challenge",
      scopes: ["operator.read"],
      token: token
    )
    #expect(parameters.objectValue?["auth"]?.objectValue?["token"]?.stringValue == token)
    #expect(parameters.objectValue?["device"]?.objectValue?["signedAt"]?.intValue == signedAt)
  }

  @Test("local CLI install requires a reviewed digest and a matching redownload")
  func localCLIInstallerDigestBoundary() async throws {
    let reviewed = Data("#!/bin/sh\nexit 0\n".utf8)
    let changed = Data("#!/bin/sh\nexit 1\n".utf8)
    let downloads = InstallerDownloads([reviewed, changed])
    let installer = LocalACPRuntimeInstaller(
      installerFetcher: { source, destination, maximumBytes in
        try await downloads.fetch(
          source: source,
          destination: destination,
          maximumBytes: maximumBytes
        )
      },
      executableResolver: { _ in URL(fileURLWithPath: "/bin/sh") }
    )
    let definition = cliDefinition()

    do {
      _ = try await installer.install(definition, component: .cli)
      Issue.record("A CLI installer must require explicit digest confirmation")
    } catch let error as LocalACPRuntimeInstallError {
      #expect(error == .confirmationRequired)
    }
    #expect(await downloads.fetchCount() == 0)

    let preview = try await installer.prepareCLIInstall(definition)
    #expect(preview.source == URL(string: "https://example.com/install.sh"))
    #expect(preview.bytes == reviewed.count)
    #expect(preview.sha256 == LocalACPManagedNodeRuntime.sha256Hex(reviewed))

    do {
      _ = try await installer.install(
        definition,
        component: .cli,
        expectedSourceSHA256: preview.sha256
      )
      Issue.record("A changed installer source must not execute")
    } catch let error as LocalACPRuntimeInstallError {
      #expect(error == .sourceDigestChanged)
    }
    #expect(await downloads.fetchCount() == 2)
  }

  @Test("local installer accepts only bounded HTTPS sources")
  func localInstallerSourceAndSizeBoundary() throws {
    #expect(LocalACPBoundedHTTPSDownloader.isSafeHTTPS(
      URL(string: "https://example.com/install.sh")!
    ))
    #expect(!LocalACPBoundedHTTPSDownloader.isSafeHTTPS(
      URL(string: "http://example.com/install.sh")!
    ))
    #expect(!LocalACPBoundedHTTPSDownloader.isSafeHTTPS(
      URL(string: "https://user@example.com/install.sh")!
    ))
    try LocalACPBoundedHTTPSDownloader.validate(
      byteCount: 5,
      maximumBytes: 5
    )
    #expect(throws: LocalACPBoundedDownloadError.tooLarge(6)) {
      try LocalACPBoundedHTTPSDownloader.validate(
        byteCount: 6,
        maximumBytes: 5
      )
    }
  }

  @Test("managed npm installs use exact reviewed package versions")
  func exactNpmInstalls() async throws {
    let fixture = try TemporaryDirectory(prefix: "wovenmatter-npm")
    defer { fixture.remove() }
    let npm = fixture.url.appending(path: "npm")
    let argumentsFile = fixture.url.appending(path: "arguments")
    try """
      #!/bin/sh
      printf '%s\\n' "$@" > "\(argumentsFile.path)"
      prefix=''
      while [ "$#" -gt 0 ]; do
        if [ "$1" = '--prefix' ]; then
          shift
          prefix="$1"
        fi
        shift
      done
      mkdir -p "$prefix/bin"
      touch "$prefix/bin/fake-acp"
      touch "$prefix/bin/fake-cli"
      chmod 700 "$prefix/bin/fake-acp"
      chmod 700 "$prefix/bin/fake-cli"
      """.write(to: npm, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: npm.path
    )
    let prefix = fixture.url.appending(path: "prefix")
    let installer = LocalACPRuntimeInstaller(
      installPrefix: prefix,
      npmExecutableURL: npm
    )
    let definition = LocalACPRuntimeDefinition(
      runtimeKind: .codex,
      displayName: "Fake",
      commandName: "fake-acp",
      arguments: [],
      underlyingCLIName: "fake",
      cliInstallerSource: nil,
      cliInstallerInterpreter: nil,
      adapterPackage: "@example/fake-acp",
      minimumAdapterVersion: "1.2.3",
      adapterDescription: "Fake adapter"
    )

    _ = try await installer.install(definition, component: .adapter)

    let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
    #expect(arguments.last == "@example/fake-acp@1.2.3")
    #expect(LocalACPRuntimeInstaller.isExactSemanticVersion("1.2.3"))
    #expect(!LocalACPRuntimeInstaller.isExactSemanticVersion("latest"))
    #expect(!LocalACPRuntimeInstaller.isExactSemanticVersion("^1.2.3"))

    let cliDefinition = LocalACPRuntimeDefinition(
      runtimeKind: .pi,
      displayName: "Fake CLI",
      commandName: "fake-cli",
      arguments: [],
      underlyingCLIName: nil,
      cliInstallerSource: URL(string: "https://www.npmjs.com/package/@example/fake-cli"),
      cliInstallerInterpreter: nil,
      cliNpmPackageSpec: "@example/fake-cli@4.5.6",
      adapterPackage: nil,
      adapterDescription: "Fake CLI"
    )
    let preview = try await installer.prepareCLIInstall(cliDefinition)
    #expect(preview.packageSpec == "@example/fake-cli@4.5.6")
    #expect(preview.verification == "npm-registry-integrity")
    do {
      _ = try await installer.install(cliDefinition, component: .cli)
      Issue.record("An npm CLI install must require package confirmation")
    } catch let error as LocalACPRuntimeInstallError {
      #expect(error == .confirmationRequired)
    }
    _ = try await installer.install(
      cliDefinition,
      component: .cli,
      expectedPackageSpec: preview.packageSpec
    )
    let cliArguments = try String(contentsOf: argumentsFile, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
    #expect(cliArguments.last == "@example/fake-cli@4.5.6")
    #expect(LocalACPRuntimeInstaller.isExactPackageSpec(
      "@example/fake-cli@4.5.6"
    ))
    #expect(!LocalACPRuntimeInstaller.isExactPackageSpec(
      "@example/fake-cli@latest"
    ))
  }

  private func entries(at root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
  }

  private static let statusJSON = #"{"id":"container","name":"wovenmatter-work-1","state":"running","running":true,"health":null,"startedAt":"now","image":"wovenmatter/workspace:0.1","memoryBytes":8589934592,"swapBytes":4294967296,"swapMode":"additional","hostPort":7440,"persistentVolume":"wovenmatter-work-1-home","capabilities":{"memory":true,"swap":true},"storageKind":"named-volume","storageUsedBytes":1048576,"hostStorageCapacityBytes":107374182400,"hostStorageAvailableBytes":53687091200,"hostStorageLow":false,"storageWarning":null,"legacyStorage":false}"#

  private func cliDefinition() -> LocalACPRuntimeDefinition {
    LocalACPRuntimeDefinition(
      runtimeKind: .codex,
      displayName: "Fake",
      commandName: "fake",
      arguments: [],
      underlyingCLIName: "fake",
      cliInstallerSource: URL(string: "https://example.com/install.sh"),
      cliInstallerInterpreter: "sh",
      adapterPackage: nil,
      adapterDescription: "Fake CLI"
    )
  }
}

private actor InstallerDownloads {
  private var payloads: [Data]
  private var count = 0

  init(_ payloads: [Data]) { self.payloads = payloads }

  func fetch(
    source: URL,
    destination: URL,
    maximumBytes: Int
  ) throws -> Int {
    guard LocalACPBoundedHTTPSDownloader.isSafeHTTPS(source),
          !payloads.isEmpty else {
      throw LocalACPBoundedDownloadError.transportFailed
    }
    let payload = payloads.removeFirst()
    guard payload.count <= maximumBytes else {
      throw LocalACPBoundedDownloadError.tooLarge(payload.count)
    }
    try payload.write(to: destination, options: .atomic)
    count += 1
    return payload.count
  }

  func fetchCount() -> Int { count }
}

private actor EventCollector {
  private var collected = ""
  func record(_ event: LocalACPEvent) {
    if case .assistantChunk(let text) = event { collected += text }
  }
  func text() -> String { collected }
}

private struct FakeACPProcess {
  let directory: URL
  let executable: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "wovenmatter-fake-acp-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    executable = directory.appending(path: "fake-acp")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
      #!/bin/sh
      IFS= read -r request
      printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
      IFS= read -r request
      printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"fake-session"}}'
      IFS= read -r request
      printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fake-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello from fake ACP"}}}}'
      printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
      """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct TemporaryDirectory {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class SSHRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let response: Data
  private(set) var destination: String?
  private(set) var command: String?
  private(set) var input: Data?

  init(response: String) { self.response = Data(response.utf8) }

  func record(destination: String, command: String, input: Data?) throws -> Data {
    lock.lock()
    self.destination = destination
    self.command = command
    self.input = input
    lock.unlock()
    return response
  }
}
