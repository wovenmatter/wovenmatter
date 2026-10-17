import Foundation
import EmbeddedExecution
import WovenMatterCompanion

extension CompanionModel {
  static var deviceEmbeddedTools: [[String: Any]] {
    [["name": "execute_command",
      "description": "Run a bundled command in this conversation's on-device workspace. Pass argv, not shell syntax. Available: python/python3 (-c, -m or script), sqlite3, wovenmatter, pwd, ls, cat, mkdir, cp, mv, rm, find, grep, help. Python has its standard library, real SQLite and await wovenmatter([group, command, ...]); prepend --target central to CLI arguments for the paired Mac. There are no OS subprocesses, sockets, package downloads or unrestricted host files. Commands have no elapsed-time cutoff; Stop cancels execution and discards uncommitted file changes. Native CLI effects retain their receipts. Output is saved to files with a bounded inline preview. Uses this chat's approval mode.",
      "parameters": ["type": "object", "properties": [
        "argv": ["type": "array", "items": ["type": "string"], "minItems": 1],
        "stdin": ["type": "string"], "workingDirectory": ["type": "string"]],
        "required": ["argv"], "additionalProperties": false]]]
  }

  func performEmbeddedDeviceCommand(arguments: [String: Any], conversationID: String, toolCallID: String) async throws -> String {
    guard let argv = arguments["argv"] as? [String], !argv.isEmpty else {
      throw DeviceExecutionError.unavailable("Pass the command and arguments as an argv array.")
    }
    let workingDirectory = arguments["workingDirectory"] as? String ?? ""
    let root = try deviceWorkspaceURL(conversationID: conversationID, path: "", directory: true)
    try await requireDeviceApproval(id: toolCallID, conversationID: conversationID,
      title: "Run on-device command", detail: String(argv.joined(separator: " ").prefix(4_000)))
    try Task.checkCancellation()
    let id = UUID(uuidString: Self.deviceCLIRequestID(toolCallID))!
    let executor = EmbeddedCommandExecutor()
    let result = try await executor.run(.init(id: id, argv: argv, stdin: arguments["stdin"] as? String ?? "",
      workingDirectory: workingDirectory), workspaceURL: root, importFiles: { arguments, json in
        var argv = arguments
        if argv.first == "--target" {
          guard argv.count >= 3, argv[1] == "local" else { return [] }
          argv.removeFirst(2)
        }
        let command = try WovenMatterToolCommand(argv)
        guard command.group == .library, command.action == "read", !command.wantsHelp,
              let data = json.data(using: .utf8) else { return [] }
        let response = try JSONDecoder().decode(WovenMatterToolResponse.self, from: data)
        guard response.success,
              case let .string(path)? = response.result?.objectValue?["workspacePath"] else { return [] }
        return [path]
      }) { [weak self] arguments, requestID in
        guard let self else { throw CancellationError() }
        var argv = arguments, target = "local"
        if argv.first == "--target" {
          guard argv.count >= 3 else { throw DeviceExecutionError.unavailable("Pass --target local or --target central before the command group.") }
          target = argv.remove(at: 1); argv.removeFirst()
        }
        return try await self.performDeviceCLI(arguments: argv, conversationID: conversationID,
          requestID: requestID, target: target)
      }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output = String(decoding: try encoder.encode(result), as: UTF8.self)
    return try Self.toolJSON(["content": [["type": "text", "text": output]], "isError": result.exitCode != 0,
      "details": ["exitCode": result.exitCode, "stdoutPath": result.stdoutPath, "stderrPath": result.stderrPath,
        "changedFiles": result.changedFiles, "removedFiles": result.removedFiles]])
  }
}
