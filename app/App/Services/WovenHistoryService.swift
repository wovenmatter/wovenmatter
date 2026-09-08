import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore

extension GatewayJSONValue: WovenSocketResponse {
  static func socketError(_ error: any Error) -> Self {
    .object(["error": .string(error.localizedDescription)])
  }
}

typealias WovenHistoryService = WovenSocketService<WorkspaceHistoryQuery, GatewayJSONValue>

// MARK: - Workspace history / session messaging CLI
// The app service supplies the caller identity; the CLI cannot choose a sender.
enum WovenHistoryCommandLine {
  static let usage = """
    Usage: woven-history COMMAND [OPTIONS]
      conversations | runs | events
      search TEXT
      conversation ID | trace RUN_ID | event EVENT_ID [--offset N --characters N]
      versions NOTE_ID | version VERSION_ID
      send SESSION_ID --text TEXT [--request-id ID]

    Query options: --conversation ID --run ID --harness NAME --kind TYPE
      --since ISO8601 --until ISO8601 --after CURSOR --limit 1...200 --json
    History commands are read-only. send explicitly dispatches a session message.
    WOVEN_HISTORY_SOCKET selects the backend's session-bound endpoint.
    """ + "\n"

  static func request(arguments: [String]) throws -> WorkspaceHistoryQuery {
    var args = arguments
    guard !args.isEmpty else { throw WovenNoteCLIError.missingArgument("command") }
    let command = args.removeFirst()
    var query = WorkspaceHistoryQuery(command: command)
    if ["conversation", "trace", "event", "versions", "version", "send", "search"].contains(command)
    {
      guard !args.isEmpty else { throw WovenNoteCLIError.missingArgument("ID or search text") }
      if command == "search" {
        query.search = args.removeFirst()
      } else {
        query.id = args.removeFirst()
      }
    }
    while !args.isEmpty {
      let flag = args.removeFirst()
      if flag == "--json" { continue }
      guard !args.isEmpty else { throw WovenNoteCLIError.missingArgument(flag) }
      let value = args.removeFirst()
      switch flag {
      case "--conversation": query.conversationID = value
      case "--run": query.runID = value
      case "--harness": query.harness = value
      case "--kind": query.kind = value
      case "--since": query.since = value
      case "--until": query.until = value
      case "--after":
        guard let n = Int64(value), n >= 0 else { throw WovenNoteCLIError.invalidInteger(flag) }
        query.after = n
      case "--limit":
        guard let n = Int(value), (1...200).contains(n) else {
          throw WovenNoteCLIError.invalidInteger(flag)
        }
        query.limit = n
      case "--offset":
        guard let n = Int(value), n >= 0, n < Int.max else {
          throw WovenNoteCLIError.invalidInteger(flag)
        }
        query.offset = n
      case "--characters":
        guard let n = Int(value), (1...65536).contains(n) else {
          throw WovenNoteCLIError.invalidInteger(flag)
        }
        query.characters = n
      case "--text": query.message = value
      case "--request-id": query.requestID = value
      default: throw WovenNoteCLIError.unknownCommand(flag)
      }
    }
    return query
  }

  static func run(arguments: [String], environment: [String: String]) -> Int32 {
    if arguments.isEmpty || ["help", "--help", "-h"].contains(arguments[0]) {
      FileHandle.standardOutput.write(Data(usage.utf8))
      return EXIT_SUCCESS
    }
    do {
      let request = try request(arguments: arguments)
      guard let path = environment["WOVEN_HISTORY_SOCKET"] else {
        throw WovenNoteCLIError.missingEnvironment("WOVEN_HISTORY_SOCKET")
      }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw WovenNoteSocketError.system(errno) }
      defer { Darwin.close(descriptor) }
      try configureSocket(descriptor)
      var address = try unixAddress(path: path)
      let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard status == 0 else { throw WovenNoteSocketError.system(errno) }
      try writeMessage(JSONEncoder().encode(request), to: descriptor, timeout: 30)
      _ = Darwin.shutdown(descriptor, SHUT_WR)
      let data = try readMessage(from: descriptor, timeout: 60, maximumBytes: 64 * 1024 * 1024)
      let result = try JSONDecoder().decode(GatewayJSONValue.self, from: data)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return result.objectValue?["error"] == nil ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
      FileHandle.standardError.write(Data("woven-history: \(error.localizedDescription)\n".utf8))
      return EXIT_FAILURE
    }
  }
}

/// A private stdio bridge runs inside the remote container. SSH authenticates the
/// existing host; the backend endpoint binds the originating WovenMatter session.
final class WovenHistoryRemoteBridge: @unchecked Sendable {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  let remoteCLIPath: String

  init(
    configuration: RemoteWorkspaceConfiguration, conversationID: String,
    ownerID: String, localSocket: String, source: String
  ) throws {
    guard UUID(uuidString: conversationID) != nil, UUID(uuidString: ownerID) != nil,
      configuration.workspaceID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,47}$/) != nil
    else {
      throw WovenNoteCLIError.unknownCommand("Invalid workspace/session identity")
    }
    let destination = try RemoteWorkspaceSSHClient.validatedDestination(
      hostName: configuration.hostName, userName: configuration.userName
    )
    // Short paths stay within sockaddr_un limits on both platforms.
    let directory =
      "/home/.wmh/\(ownerID.replacingOccurrences(of:"-",with:""))/\(conversationID.replacingOccurrences(of:"-",with:""))"
    remoteCLIPath = directory + "/woven-history"
    let encoded = Data(source.utf8).base64EncodedString()
    let bootstrap =
      "import base64; source=base64.b64decode('\(encoded)').decode(); exec(compile(source, '<woven-history>', 'exec'))"
    func quote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    let command = [
      "docker", "exec", "--interactive", "wovenmatter-\(configuration.workspaceID)",
      "python3", "-c", bootstrap, "--relay", directory,
    ].map(quote).joined(separator: " ")
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=2", destination, command,
    ]
    let stdin = Pipe()
    let stdout = Pipe()
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    try process.run()
    let input = input
    let output = output
    let ready = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      defer {
        try? input.close()
        try? output.close()
      }
      var pending = Data()
      while let chunk = try? output.read(upToCount: 65536), !chunk.isEmpty {
        pending.append(chunk)
        if pending.count > 8 * 1024 * 1024 { break }
        while let newline = pending.firstIndex(of: 10) {
          let line = Data(pending[..<newline])
          pending.removeSubrange(...newline)
          if line == Data("READY".utf8) {
            ready.signal()
            continue
          }
          let response: Data
          do {
            guard let request = Data(base64Encoded: Data(line)) else {
              throw WovenNoteSocketError.requestTooLarge
            }
            response = try Self.forward(request, to: localSocket)
          } catch {
            response = (try? JSONEncoder().encode(["error": error.localizedDescription])) ?? Data()
          }
          do {
            try input.write(contentsOf: Data((response.base64EncodedString() + "\n").utf8))
          } catch { return }
        }
      }
    }
    guard ready.wait(timeout: .now() + 15) == .success else {
      try? input.close()
      if process.isRunning { process.terminate() }
      throw WovenNoteSocketError.timedOut
    }
  }

  var isRunning: Bool { process.isRunning }
  deinit {
    try? input.close()
    if process.isRunning { process.terminate() }
  }

  private static func forward(_ data: Data, to path: String) throws -> Data {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw WovenNoteSocketError.system(errno) }
    defer { Darwin.close(descriptor) }
    try configureSocket(descriptor)
    var address = try unixAddress(path: path)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard status == 0 else { throw WovenNoteSocketError.system(errno) }
    try writeMessage(data, to: descriptor, timeout: 30)
    _ = Darwin.shutdown(descriptor, SHUT_WR)
    return try readMessage(from: descriptor, timeout: 60, maximumBytes: 64 * 1024 * 1024)
  }
}
