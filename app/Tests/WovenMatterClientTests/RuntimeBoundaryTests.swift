#if os(macOS)
import Foundation
import Testing
@testable import WovenMatterClient
@testable import WovenMatterCore

@Suite("Runtime boundaries", .serialized)
struct RuntimeBoundaryTests {

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
      printf '#!/bin/sh\\necho 1.2.4\\n' > "$prefix/bin/fake-acp"
      printf '#!/bin/sh\\necho 1.5.6\\n' > "$prefix/bin/fake-cli"
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
      npmExecutableURL: npm,
      metadataFetcher: { _ in Data(#"{"version":"1.2.4","bin":{"cli":"bin.js"}}"#.utf8) }
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
    #expect(arguments.last == "@example/fake-acp@1.2.4")
    #expect(LocalACPRuntimeInstaller.isExactSemanticVersion("1.2.3"))
    #expect(!LocalACPRuntimeInstaller.isExactSemanticVersion("latest"))
    #expect(!LocalACPRuntimeInstaller.isExactSemanticVersion("^1.2.3"))

    #expect(LocalACPRuntimeInstaller.isExactPackageSpec(
      "@example/fake-cli@1.5.6"
    ))
    #expect(!LocalACPRuntimeInstaller.isExactPackageSpec(
      "@example/fake-cli@latest"
    ))
  }


  @Test("remote commands preserve data and reject unsafe input")
  func remoteWorkspaceBoundary() async throws {
    let configuration = RemoteWorkspaceConfiguration(
      name: "Work",
      workspaceID: "work-1",
      hostName: "linux-box",
      userName: "woven",
      remotePort: 7440
    )

    let deleteRecorder = SSHRecorder(response: #"{"deleted":true}"#)
    let deleteClient = RemoteWorkspaceSSHClient(
      runner: { destination, command, input in
        try deleteRecorder.record(destination: destination, command: command, input: input)
      },
      scriptLoader: { Data("script".utf8) }
    )
    try await deleteClient.delete(configuration: configuration, removePersistentData: false)
    #expect(deleteRecorder.command == "exec bash -s -- 'uninstall' 'work-1'")
    try await deleteClient.delete(configuration: configuration, removePersistentData: true)
    #expect(deleteRecorder.command == "exec bash -s -- 'uninstall' 'work-1' '--data'")

    #expect(throws: RemoteWorkspaceClientError.self) {
      try RemoteWorkspaceSSHClient.validatedDestination(
        hostName: "-oProxyCommand=bad",
        userName: nil
      )
    }
  }

  @Test("local CLI install runs the official installer as published; a digest someone saw must still match")
  func localCLIInstallerDigestBoundary() async throws {
    let published = Data("#!/bin/sh\nexit 0\n".utf8)
    let changed = Data("#!/bin/sh\nexit 1\n".utf8)
    let downloads = InstallerDownloads([published, published, changed])
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

    // A missing CLI installs with nothing to review.
    _ = try await installer.install(definition, component: .cli)
    #expect(await downloads.fetchCount() == 1)

    // Another Mac that showed a download passes its digest; a changed download never runs.
    let preview = try await installer.prepareCLIInstall(definition)
    #expect(preview.source == URL(string: "https://example.com/install.sh"))
    #expect(preview.bytes == published.count)
    #expect(preview.sha256 == "306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb")
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
    #expect(await downloads.fetchCount() == 3)
  }

  @Test("Claude's official installer runs with the catalog's arguments and installs what its channel names")
  func claudeInstallerUsesItsOwnChannel() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = Data("#!/bin/sh\n[ \"$1\" = latest ] && [ $# -eq 1 ]\n".utf8)
    let installer = LocalACPRuntimeInstaller(
      installPrefix: root,
      installerFetcher: { _, destination, _ in try script.write(to: destination); return script.count },
      metadataFetcher: { url in
        Issue.record("A CLI install never asks npm which version to install: \(url)")
        throw RuntimeMaintenanceError.unavailable
      },
      executableResolver: { _ in URL(fileURLWithPath: "/bin/sh") }
    )
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: .claudeCode))
    #expect(definition.cliInstallerArguments == ["latest"])
    let executable = try await installer.install(definition, component: .cli)
    #expect(executable.path == "/bin/sh")
  }
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
  private(set) var command: String?

  init(response: String) { self.response = Data(response.utf8) }

  func record(destination: String, command: String, input: Data?) throws -> Data {
    lock.lock()
    self.command = command
    lock.unlock()
    return response
  }
}

extension RuntimeBoundaryTests {
  @Test("an adapter installs alone, pointed at the native CLI, with its protocol SDK selected before staging")
  func adapterInstallUsesTheNativeCLI() async throws {
    let fixture = try TemporaryDirectory(prefix: "woven-independent-engine")
    defer { fixture.remove() }
    let tools = fixture.url.appending(path: "tools")
    let prefix = fixture.url.appending(path: "installed")
    let argumentsFile = fixture.url.appending(path: "arguments")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let npm = tools.appending(path: "npm"), node = tools.appending(path: "node")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: npm)
    try Data("""
      #!/bin/sh
      printf '%s\\n' "$@" > '\(argumentsFile.path)'
      mkdir -p '\(prefix.path)/bin'
      printf '#!/bin/sh\\necho 2.6.0\\n' > '\(prefix.path)/bin/codex-acp'
      chmod 700 '\(prefix.path)/bin/codex-acp'
      """.utf8).write(to: node)
    for path in [node, npm] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
    let nativeCodex = URL(fileURLWithPath: "/home/someone/.local/bin/codex")
    let installer = LocalACPRuntimeInstaller(installPrefix: prefix, npmExecutableURL: npm, metadataFetcher: { url in
      #expect(url.absoluteString.contains("@agentclientprotocol%2fsdk"), "no engine is looked up: \(url)")
      return Data(#"{"dist-tags":{"latest":"2.1.0"},"versions":{"2.1.0":{},"2.7.0":{},"2.8.0":{"deprecated":"withdrawn"},"3.0.0-beta.1":{}}}"#.utf8)
    }, executableResolver: { name in name == "codex" ? nativeCodex : nil })
    let executable = try await installer.installPackage("@agentclientprotocol/codex-acp", version: "2.6.0", executableName: "codex-acp")
    let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n")
    #expect(arguments.count == 2)
    #expect(arguments[0].hasSuffix("harnesses/install-adapter.mjs"))
    let selection = try #require(JSONSerialization.jsonObject(with: Data(arguments[1].utf8)) as? [String: Any])
    #expect(selection["engineVersion"] == nil)
    #expect(selection["cli"] as? String == nativeCodex.path)
    #expect(selection["protocolSDKVersion"] as? String == "2.7.0")
    #expect(selection["adapterVersion"] as? String == "2.6.0")
    #expect(selection["npm"] as? [String] == [npm.path])
    #expect(executable == prefix.appending(path: "bin/codex-acp"))
  }
}
#endif
