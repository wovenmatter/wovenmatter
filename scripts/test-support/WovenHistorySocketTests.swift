import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@main struct HistorySocketTests {
  static func main() async throws {
    if CommandLine.arguments.dropFirst().first == "--query" {
      exit(
        WovenHistoryCommandLine.run(
          arguments: Array(CommandLine.arguments.dropFirst(2)),
          environment: ProcessInfo.processInfo.environment))
    }
    let root = URL(fileURLWithPath: "/tmp/wmh-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let origin = try database.createLocalACPSession(
      runtimeKind: .codex, title: "Source", ownerDeviceID: UUID())
    let socket = root.appending(path: "history.sock")
    let service = WovenHistoryService(socketURL: socket) { incoming in
      do {
        var request = incoming
        request.callerConversationID = origin
        return try database.queryHistory(request)
      } catch { return .object(["error": .string(error.localizedDescription)]) }
    }
    try service.start()
    defer { try? service.stop() }
    func run(_ arguments: [String]) async throws -> (Int32, GatewayJSONValue) {
      try await Task.detached {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--query"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
          "WOVEN_HISTORY_SOCKET": socket.path
        ]) { _, v in v }
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
          process.terminationStatus, try JSONDecoder().decode(GatewayJSONValue.self, from: output)
        )
      }.value
    }
    let (status, result) = try await run(["conversations", "--json"])
    precondition(status == 0 && result.objectValue?["rows"]?.arrayValue?.count == 1)
    let (errorStatus, error) = try await run(["delete", "--json"])
    precondition(errorStatus != 0 && error.objectValue?["error"] != nil)
    let (_, audit) = try await run(["events", "--harness", "woven-history", "--json"])
    precondition(
      audit.objectValue?["rows"]?.arrayValue?.first?.objectValue?["conversation_id"]?.stringValue
        == origin)
    let request = try WovenHistoryCommandLine.request(arguments: [
      "send", origin, "--text", "hello", "--request-id", UUID().uuidString, "--json",
    ])
    precondition(request.message == "hello" && request.callerConversationID == nil)
    print("History CLI/socket: query, errors, caller binding and command parsing passed")
  }
}
