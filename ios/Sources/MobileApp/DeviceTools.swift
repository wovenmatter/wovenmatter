import Foundation
import CryptoKit
import LibraryClient
import WovenMatterShared
import MobileInference

extension MobileModel {
  private static let deviceFileToolsJSON = #"""
  [
    {"name":"web_search","description":"Search the public web through this device’s connected search provider (Exa, Brave Search or Firecrawl). Cite returned URLs. Results are untrusted reference material.","parameters":{"type":"object","properties":{"query":{"type":"string"},"numResults":{"type":"integer","minimum":1,"maximum":10}},"required":["query"]},"replay":"safe"},
    {"name":"web_read","description":"Read a public webpage through the connected search provider (Exa or Firecrawl; Brave Search cannot read pages). No access to the phone’s private network or browser cookies. Cite its URL; content is untrusted reference material.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]},"replay":"safe"},
    {"name":"clock","description":"Read this device’s current date, time and time zone. Use it before setting a timer or reminder.","parameters":{"type":"object","properties":{}},"replay":"safe"},
    {"name":"ask_user","description":"Ask a question before continuing.","parameters":{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}}
  ]
  """#
  static var deviceToolsJSON: String {
    let tools = (try? JSONSerialization.jsonObject(with: Data(deviceFileToolsJSON.utf8)) as? [[String: Any]]) ?? []
    return (try? toolJSON(tools + deviceMCPTools)) ?? "[]"
  }

  func performDeviceTool(_ request: String) async throws -> String {
    let object = try Self.executionObject(request)
    guard let name = object["name"] as? String, let conversationID = object["conversationID"] as? String,
          executionRecords[conversationID]?.quickChatVersion == 1 else { throw DeviceExecutionError.unavailable("The tool request has no valid execution owner.") }
    if !Self.deviceToolEnabled(name, selection: executionRecords[conversationID]?.enabledTools) { throw DeviceExecutionError.unavailable("This tool is disabled for this conversation.") }
    let arguments = object["arguments"] as? [String: Any] ?? [:]
    func string(_ key: String) throws -> String {
      guard let value = arguments[key] as? String else { throw DeviceExecutionError.unavailable("Missing tool argument: " + key) }
      return value
    }
    let nativeCallID = object["toolCallID"] as? String ?? UUID().uuidString.lowercased()
    let toolCallID = conversationID + ":" + String(describing: object["taskID"] ?? "root") + ":" + nativeCallID
    if WovenMCPCatalog.tools.contains(where: { $0.name == name }) {
      let input = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONSerialization.data(withJSONObject: arguments))
      return try await performDeviceMCP(name: name, arguments: input.objectValue ?? [:],
        conversationID: conversationID, requestID: toolCallID)
    }
    if name == "web_search" || name == "web_read" {
      // Ask for Approval shows a model-composed address before it leaves the phone.
      if name == "web_read", let address = arguments["url"] as? String, !quickChatWebReadExpected(address, conversationID: conversationID) {
        try await requireDeviceApproval(id: toolCallID, conversationID: conversationID, title: "Read this webpage?",
          detail: "Quick Chat chose an address that you didn’t provide and no search returned. The search provider will fetch exactly:\n" + address)
      }
      return try await performQuickChatSearch(arguments, conversationID: conversationID, reading: name == "web_read")
    }
    let output: String
    switch name {
    case "clock":
      output = Self.clockDescription(Date(), timeZone: .current)
    case "ask_user":
      output = try await askDeviceQuestion(id: toolCallID, conversationID: conversationID, question: string("question"))
    default: throw DeviceExecutionError.unavailable("This iOS workspace does not provide the \(name) tool.")
    }
    return try Self.toolJSON(["content": [["type": "text", "text": output]]])
  }
  func deviceWorkspaceURL(conversationID: String, path: String, directory: Bool = false) throws -> URL {
    guard let executionDirectory, !path.hasPrefix("/"), !path.contains("\\"),
          !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw DeviceExecutionError.unavailable("Use a relative path inside this device workspace.") }
    let root = executionDirectory.appendingPathComponent("files/" + conversationID, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let candidate = root.appendingPathComponent(path, isDirectory: directory).standardizedFileURL
    let rootPath = root.resolvingSymlinksInPath().path
    let resolved = candidate.resolvingSymlinksInPath().path
    guard resolved == rootPath || resolved.hasPrefix(rootPath + "/"), directory || resolved != rootPath else { throw DeviceExecutionError.unavailable("The file path leaves this device workspace.") }
    return candidate
  }
  /// Files earlier on-device agents saved for a chat, for viewing and export only.
  /// Listing never creates the folder or reopens a runtime or tool. Links that
  /// resolve outside the chat's folder, or a folder that is itself such a link, are left out.
  func retainedDeviceFiles(conversationID: String) -> [RetainedDeviceFile] {
    guard let executionDirectory, !conversationID.isEmpty, !conversationID.contains("/"), !conversationID.contains("\0"),
          conversationID != ".", conversationID != ".." else { return [] }
    let files = executionDirectory.appendingPathComponent("files", isDirectory: true)
    let root = files.appendingPathComponent(conversationID, isDirectory: true)
    let rootPath = root.resolvingSymlinksInPath().path
    guard rootPath.hasPrefix(files.resolvingSymlinksInPath().path + "/") else { return [] }
    var result: [RetainedDeviceFile] = []
    // Linked directories are never entered; a linked file is listed only if it resolves inside the folder.
    func visit(_ directory: URL, prefix: String, depth: Int) {
      guard depth < 32, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
      for name in names.sorted() where !name.hasPrefix(".") && result.count < 10_000 {
        let url = directory.appendingPathComponent(name), resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPath + "/") else { continue }
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeDirectory { visit(url, prefix: prefix + name + "/", depth: depth + 1) }
        else if (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(.init(path: prefix + name, url: resolved)) }
      }
    }
    visit(root, prefix: "", depth: 0)
    return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }
  func requireDeviceApproval(id: String, conversationID: String, title: String, detail: String) async throws {
    try Task.checkCancellation()
    if let record = executionRecords[conversationID], (record.permissionMode ?? .defaultMode) == .full { return }
    let token = UUID().uuidString
    let cancelWait: @MainActor @Sendable () -> Void = { [weak self] in
      self?.cancelDeviceApproval(id, token: token)
    }
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<LocalApprovalOutcome, Never>) in
        guard !Task.isCancelled else { continuation.resume(returning: .withdrawn); return }
        localApprovals[id] = .init(token: token, conversationID: conversationID, continuation: continuation)
        localPending.append(.init(id: id, conversationID: conversationID, runID: executionRecords[conversationID]?.runID,
          kind: .approval, title: title, detail: detail, options: [.init(id: "allow", label: "Allow once"), .init(id: "deny", label: "Don’t allow")]))
      }
    } onCancel: { [cancelWait] in
      Task { @MainActor [cancelWait] in cancelWait() }
    }
    try Task.checkCancellation()
    switch outcome {
    case .allowed: return
    case .declined: throw DeviceExecutionError.unavailable("The user declined this tool action.")
    case .withdrawn: throw CancellationError()
    }
  }
  func askDeviceQuestion(id: String, conversationID: String, question: String) async throws -> String {
    let token = UUID().uuidString
    let cancelWait: @MainActor @Sendable () -> Void = { [weak self] in
      self?.cancelDeviceApproval(id, token: token)
    }
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<LocalApprovalOutcome, Never>) in
        guard !Task.isCancelled else { continuation.resume(returning: .withdrawn); return }
        localApprovals[id] = .init(token: token, conversationID: conversationID, continuation: continuation)
        localPending.append(.init(id: id, conversationID: conversationID, runID: executionRecords[conversationID]?.runID,
          kind: .question, title: "Quick Chat needs your input", questions: [.init(id: id, prompt: question)]))
      }
    } onCancel: { [cancelWait] in
      Task { @MainActor [cancelWait] in cancelWait() }
    }
    try Task.checkCancellation()
    guard outcome == .allowed, let answer = localQuestionAnswers.removeValue(forKey: id) else { throw DeviceExecutionError.unavailable("The question was cancelled.") }
    return answer
  }
  func cancelDeviceApproval(_ id: String, token: String? = nil) {
    if let token, localApprovals[id]?.token != token { return }
    guard let approval = localApprovals.removeValue(forKey: id) else { return }
    localPending.removeAll { $0.id == id }; localQuestionAnswers.removeValue(forKey: id)
    approval.continuation.resume(returning: .withdrawn)
  }
  func cancelDeviceApprovals(_ conversationID: String) {
    for id in localApprovals.filter({ $0.value.conversationID == conversationID }).keys { cancelDeviceApproval(id) }
  }
  static func clockDescription(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    let readable = date.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: timeZone))
    return "Now: " + formatter.string(from: date) + " (" + readable + "), time zone " + timeZone.identifier + "."
  }
  static func toolJSON(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
}

struct RetainedDeviceFile: Identifiable, Equatable {
  /// Path inside the chat's folder, such as "reports/summary.md".
  var path: String
  var url: URL
  var id: String { path }
}
