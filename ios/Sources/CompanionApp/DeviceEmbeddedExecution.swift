import Foundation
import EmbeddedExecution
import WovenMatterCompanion

extension CompanionModel {
  static var deviceEmbeddedTools: [[String: Any]] {
    [["name": "execute_command",
      "description": "Run a bundled command in this conversation's on-device workspace. Pass argv, not shell syntax. Available: python/python3 (-c, -m or script), sqlite3, pwd, ls, cat, mkdir, cp, mv, rm, find, grep, help. Python has its standard library, real SQLite and await woven_mcp(tool_name, arguments) for the same focused Woven MCP tools. Read workspace files in Python and pass their contents as typed tool arguments. Choose target=central in a tool's argument object only for an explicitly requested paired Mac operation. There are no OS subprocesses, sockets, package downloads or unrestricted host files. Stop cancels execution and discards uncommitted file changes. Accepted MCP effects retain their receipts. Output is saved to files with a bounded inline preview. Uses this chat's approval mode.",
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
    let id = UUID(uuidString: Self.deviceMCPRequestID(toolCallID))!
    let executor = EmbeddedCommandExecutor()
    let result = try await executor.run(.init(id: id, argv: argv, stdin: arguments["stdin"] as? String ?? "",
      workingDirectory: workingDirectory), workspaceURL: root, importFiles: { name, argumentsJSON, json in
        guard name == "woven_library_read",
              let input = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any],
              (input["target"] as? String ?? "local") == "local",
              let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let response = result["structuredContent"] as? [String: Any], response["success"] as? Bool == true,
              let payload = response["result"] as? [String: Any], let path = payload["workspacePath"] as? String else { return [] }
        return [path]
      }) { [weak self] name, argumentsJSON, requestID in
        guard let self else { throw CancellationError() }
        let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(argumentsJSON.utf8))
        guard let arguments = input.objectValue else { throw DeviceExecutionError.unavailable("MCP tool arguments must be an object.") }
        return try await self.performDeviceMCP(name: name, arguments: arguments,
          conversationID: conversationID, requestID: requestID)
      }

    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output = String(decoding: try encoder.encode(result), as: UTF8.self)
    return try Self.toolJSON(["content": [["type": "text", "text": output]], "isError": result.exitCode != 0,
      "details": ["exitCode": result.exitCode, "stdoutPath": result.stdoutPath, "stderrPath": result.stderrPath,
        "changedFiles": result.changedFiles, "removedFiles": result.removedFiles]])
  }
}
