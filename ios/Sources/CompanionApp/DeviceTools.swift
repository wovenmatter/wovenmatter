import Foundation
import PDFKit
import UIKit
import ImageIO
import CryptoKit
import CompanionClient
import WovenMatterCompanion

private final class DeviceToolNetworkDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

extension CompanionModel {
  static let deviceToolsJSON = #"""
  [
    {"name":"list_notes","description":"List notes available on this device, optionally filtering titles and content. Returns note IDs and revisions.","parameters":{"type":"object","properties":{"query":{"type":"string"}}},"replay":"safe"},
    {"name":"read_note","description":"Read a locally available Woven Matter note by ID.","parameters":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"replay":"safe"},
    {"name":"save_note","description":"Create a note or update an existing note. Updates require id and the localVersion returned by read_note. Content is plain text. Asks the user for approval and queues central synchronization.","parameters":{"type":"object","properties":{"id":{"type":"string"},"revision":{"type":"integer"},"localVersion":{"type":"string"},"title":{"type":"string"},"content":{"type":"string"},"folderID":{"type":"string"}},"required":["title","content"]}},
    {"name":"list_files","description":"List files inside this conversation's device workspace. Paths are relative; no unrestricted filesystem access.","parameters":{"type":"object","properties":{"path":{"type":"string"}}},"replay":"safe"},
    {"name":"read_file","description":"Read a UTF-8 file in this conversation's device workspace, up to 1 MiB.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"replay":"safe"},
    {"name":"read_document","description":"Extract text from an imported PDF or UTF-8 document in this workspace, up to 20 MiB. Scanned PDFs may have no text.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"replay":"safe"},
    {"name":"read_image","description":"Read an imported image from this workspace for the model. Requires permission before sending the image to the inference provider.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
    {"name":"write_file","description":"Write a UTF-8 file in this conversation's device workspace. Requires user approval. Workspace files remain on this device unless saved to the library.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
    {"name":"fetch_url","description":"Retrieve a user-approved HTTPS URL as text, up to 1 MiB. Does not follow redirects or use browser cookies.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}},
    {"name":"ask_user","description":"Ask the user a question before continuing.","parameters":{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}}
  ]
  """#

  func performDeviceTool(_ request: String) async throws -> String {
    let object = try Self.executionObject(request)
    guard let name = object["name"] as? String, let conversationID = object["conversationID"] as? String,
          executionRecords[conversationID] != nil else { throw DeviceExecutionError.unavailable("The tool request has no valid execution owner.") }
    if let enabled = executionRecords[conversationID]?.enabledTools, !enabled.contains(name) { throw DeviceExecutionError.unavailable("This tool is disabled for this conversation.") }
    let arguments = object["arguments"] as? [String: Any] ?? [:]
    func string(_ key: String) throws -> String {
      guard let value = arguments[key] as? String else { throw DeviceExecutionError.unavailable("Missing tool argument: " + key) }
      return value
    }
    let nativeCallID = object["toolCallID"] as? String ?? UUID().uuidString.lowercased()
    let toolCallID = conversationID + ":" + String(describing: object["taskID"] ?? "root") + ":" + nativeCallID
    var output: String
    switch name {
    case "list_notes":
      await reload()
      let query = arguments["query"] as? String ?? ""
      let matched = notes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.content.localizedCaseInsensitiveContains(query) }
      output = try Self.toolJSON(matched.prefix(100).map { ["id": $0.id, "title": $0.title, "revision": $0.revision, "cached": !state.uncachedNoteIDs.contains($0.id)] as [String: Any] })
    case "read_note":
      await flushLocalWrites(); await reload()
      let id = try string("id")
      guard let note = state.notes[id], !state.uncachedNoteIDs.contains(id) else { throw DeviceExecutionError.unavailable("This note is not saved on this device. Connect to the central library to download it.") }
      var value = try Self.executionObject(String(decoding: try JSONEncoder().encode(note), as: UTF8.self))
      value["localVersion"] = try Self.noteLocalVersion(note)
      output = try Self.toolJSON(value)
    case "save_note":
      let title = try string("title"), content = try string("content")
      guard content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw DeviceExecutionError.unavailable("The note is too large.") }
      try await requireDeviceApproval(id: toolCallID, conversationID: conversationID, title: "Save note", detail: "\(title)\n\n\(String(content.prefix(2000)))")
      await flushLocalWrites()
      try Task.checkCancellation()
      guard let store else { throw CancellationError() }
      let document = try NoteDocument(blocks: [.richText(.init(text: content))]).encoded()
      if let id = arguments["id"] as? String {
        let snapshot = await store.snapshot()
        guard let note = snapshot.notes[id], arguments["localVersion"] as? String == (try Self.noteLocalVersion(note)),
              (note.kind == nil || note.kind == .note), snapshot.conflicts[id] == nil else { throw DeviceExecutionError.unavailable("The note changed or is not an editable note. Read it again and use its current localVersion before editing.") }
        try await store.editNoteIfUnchanged(id: id, title: title, content: document, folderID: note.folderID, expected: note)
        output = "Saved note \(id) on this device. Central sync is queued."
      } else {
        let note = try await store.createNote(folderID: arguments["folderID"] as? String, title: title, content: document)
        output = "Created note \(note.id) on this device. Central sync is queued."
      }
      await reload()
    case "list_files":
      let directory = try deviceWorkspaceURL(conversationID: conversationID, path: arguments["path"] as? String ?? "", directory: true)
      let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      output = try Self.toolJSON(files.prefix(200).map { url in ["name": url.lastPathComponent, "directory": (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false] as [String: Any] })
    case "read_file":
      let url = try deviceWorkspaceURL(conversationID: conversationID, path: string("path"))
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 1_024 * 1_024 else { throw DeviceExecutionError.unavailable("This file exceeds the 1 MiB text-read limit.") }
      output = try String(contentsOf: url, encoding: .utf8)
    case "read_document":
      let url = try deviceWorkspaceURL(conversationID: conversationID, path: string("path"))
      guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1_024 * 1_024 else { throw DeviceExecutionError.unavailable("This document exceeds the 20 MiB extraction limit.") }
      if url.pathExtension.lowercased() == "pdf" {
        guard let document = PDFDocument(url: url), let text = document.string else { throw DeviceExecutionError.unavailable("This PDF has no extractable text.") }
        output = String(text.prefix(1_000_000))
      } else { output = try String(contentsOf: url, encoding: .utf8) }
    case "read_image":
      let path = try string("path"), url = try deviceWorkspaceURL(conversationID: conversationID, path: path)
      guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1_024 * 1_024 else { throw DeviceExecutionError.unavailable("The image exceeds 20 MiB.") }
      try await requireDeviceApproval(id: toolCallID, conversationID: conversationID, title: "Send image to model", detail: path)
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
            let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw DeviceExecutionError.unavailable("The image could not be decoded.") }
      return try Self.toolJSON(["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]])
    case "write_file":
      let path = try string("path"), content = try string("content")
      guard content.utf8.count <= 4 * 1_024 * 1_024 else { throw DeviceExecutionError.unavailable("This file exceeds the 4 MiB write limit.") }
      try await requireDeviceApproval(id: toolCallID, conversationID: conversationID, title: "Write workspace file", detail: "\(path)\n\n\(String(content.prefix(2000)))")
      let url = try deviceWorkspaceURL(conversationID: conversationID, path: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let checked = try deviceWorkspaceURL(conversationID: conversationID, path: path)
      try Data(content.utf8).write(to: checked, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      output = "Saved \(path) in this device workspace."
    case "fetch_url":
      let address = try string("url")
      guard let url = URL(string: address), url.scheme == "https", url.host != nil,
            url.user == nil, url.password == nil else { throw DeviceExecutionError.unavailable("Use an HTTPS URL without embedded credentials.") }
      try await requireDeviceApproval(id: toolCallID, conversationID: conversationID, title: "Open web address", detail: address)
      let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 30
      let session = URLSession(configuration: configuration, delegate: DeviceToolNetworkDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      let (bytes, response) = try await session.bytes(from: url)
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DeviceExecutionError.unavailable("The website did not return a successful response. Redirects need a separate approved request.") }
      var data = Data()
      for try await byte in bytes { guard data.count < 1_024 * 1_024 else { throw DeviceExecutionError.unavailable("The web response exceeds the 1 MiB limit.") }; data.append(byte) }
      guard let content = String(data: data, encoding: .utf8) else { throw DeviceExecutionError.unavailable("The response is not UTF-8 text.") }
      output = content
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
  func requireDeviceApproval(id: String, conversationID: String, title: String, detail: String) async throws {
    let token = UUID().uuidString
    let cancelWait: @MainActor @Sendable () -> Void = { [weak self] in
      self?.cancelDeviceApproval(id, token: token)
    }
    let allowed = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        localApprovals[id] = .init(token: token, conversationID: conversationID, continuation: continuation)
        localPending.append(.init(id: id, conversationID: conversationID, runID: executionRecords[conversationID]?.runID,
          kind: .approval, title: title, detail: detail, options: [.init(id: "allow", label: "Allow once"), .init(id: "deny", label: "Don’t allow")]))
      }
    } onCancel: { [cancelWait] in
      Task { @MainActor [cancelWait] in cancelWait() }
    }
    try Task.checkCancellation()
    guard allowed else { throw DeviceExecutionError.unavailable("The user declined this tool action.") }
  }
  func askDeviceQuestion(id: String, conversationID: String, question: String) async throws -> String {
    let token = UUID().uuidString
    let cancelWait: @MainActor @Sendable () -> Void = { [weak self] in
      self?.cancelDeviceApproval(id, token: token)
    }
    let allowed = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        localApprovals[id] = .init(token: token, conversationID: conversationID, continuation: continuation)
        localPending.append(.init(id: id, conversationID: conversationID, runID: executionRecords[conversationID]?.runID,
          kind: .question, title: "Pi Durable needs your input", questions: [.init(id: id, prompt: question)]))
      }
    } onCancel: { [cancelWait] in
      Task { @MainActor [cancelWait] in cancelWait() }
    }
    try Task.checkCancellation()
    guard allowed, let answer = localQuestionAnswers.removeValue(forKey: id) else { throw DeviceExecutionError.unavailable("The question was cancelled.") }
    return answer
  }
  func cancelDeviceApproval(_ id: String, token: String? = nil) {
    if let token, localApprovals[id]?.token != token { return }
    guard let approval = localApprovals.removeValue(forKey: id) else { return }
    localPending.removeAll { $0.id == id }; localQuestionAnswers.removeValue(forKey: id)
    approval.continuation.resume(returning: false)
  }
  func cancelDeviceApprovals(_ conversationID: String) {
    for id in localApprovals.filter({ $0.value.conversationID == conversationID }).keys { cancelDeviceApproval(id) }
  }
  static func noteLocalVersion(_ note: CompanionNote) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(note)).map { String(format: "%02x", $0) }.joined()
  }
  static func toolJSON(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
}
