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
  }

  private func entries(at root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
  }

  private static let statusJSON = #"{"id":"container","name":"wovenmatter-work-1","state":"running","running":true,"health":null,"startedAt":"now","image":"wovenmatter/workspace:0.1","memoryBytes":8589934592,"swapBytes":4294967296,"swapMode":"additional","hostPort":7440,"persistentVolume":"wovenmatter-work-1-home","capabilities":{"memory":true,"swap":true},"storageKind":"named-volume","storageUsedBytes":1048576,"hostStorageCapacityBytes":107374182400,"hostStorageAvailableBytes":53687091200,"hostStorageLow":false,"storageWarning":null,"legacyStorage":false}"#
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
