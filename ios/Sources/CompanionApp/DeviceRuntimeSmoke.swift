#if DEBUG
import Foundation
import UIKit
import CompanionInference
import EmbeddedExecution
import PiDurableRuntime

private struct SmokeCredentials: InferenceCredentialReading {
  func read(connectionID: String) async throws -> String? { "controlled-smoke-value-never-sent-to-network" }
}

/// The only transport used by smoke mode is an in-memory provider fixture. No URLSession or Keychain access.
private actor SmokeInferenceTransport: InferenceHTTPTransport {
  var calls = 0
  let codeMode: Bool
  init(codeMode: Bool = false) { self.codeMode = codeMode }
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    calls += 1
    let output: [[String: Any]]
    if codeMode {
      if calls == 1 || calls == 3 {
        let code = calls == 1
          ? "await tools.write_file({text:'Code mode on iOS: café 🟩'}); const result = await tools.read_file({}); store('verified', 'persisted JS state'); text(result);"
          : "const saved = load('verified'); if(saved !== 'persisted JS state') throw new Error('JS state was not restored'); text(saved);"
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["code": code]), as: UTF8.self)
        output = [["type": "function_call", "call_id": "smoke-code-\(calls)", "name": "codemode", "arguments": arguments]]
      } else {
        output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Code-mode native tools and durable JS state verified."]]]]
      }
    } else { switch calls {
    case 1: output = [["type": "function_call", "call_id": "smoke-write", "name": "write_file", "arguments": "{\"text\":\"Saved on iOS: café 🟩\"}"]]
    case 2: output = [["type": "function_call", "call_id": "smoke-read", "name": "read_file", "arguments": "{}"]]
    default: output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Verified the native iOS file: café 🟩"]]]]
    } }
    let response: [String: Any] = ["type": "response.completed", "response": ["id": "smoke-response-\(calls)", "status": "completed", "output": output, "usage": ["input_tokens": 10, "output_tokens": 8]]]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    return AsyncThrowingStream { continuation in
      continuation.yield(.response(200)); continuation.yield(.line("data: " + text)); continuation.yield(.line("")); continuation.finish()
    }
  }
}

private actor SmokeNativeTools {
  let file: URL
  var writes = 0
  var reads = 0
  init(file: URL) { self.file = file }
  func execute(_ request: String) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any], let name = object["name"] as? String else { throw CocoaError(.coderReadCorrupt) }
    let result: String
    if name == "write_file" {
      guard let arguments = object["arguments"] as? [String: Any], let text = arguments["text"] as? String else { throw CocoaError(.coderReadCorrupt) }
      try Data(text.utf8).write(to: file, options: .atomic); writes += 1; result = "Saved native file"
    } else if name == "read_file" { result = try String(contentsOf: file, encoding: .utf8); reads += 1 }
    else { throw CocoaError(.featureUnsupported) }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": result]]]), as: UTF8.self)
  }
}

@MainActor enum DeviceRuntimeSmoke {
  static var enabled: Bool { ProcessInfo.processInfo.environment["WOVENMATTER_DEVICE_RUNTIME_SMOKE"] == "1" }
  private static var started = false
  static func run() async {
    guard enabled, !started else { return }; started = true
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let resultFile = documents.appendingPathComponent("runtime-smoke.json")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-runtime-smoke-" + UUID().uuidString)
    var result: [String: Any] = ["passed": false, "networkUsed": false, "keychainUsed": false]
    do {
      try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      result.merge(try selectableTable()) { _, new in new }
      let transport = SmokeInferenceTransport()
      let native = SmokeNativeTools(file: root.appendingPathComponent("native-note.txt"))
      let model = InferenceModel(id: "offline-smoke", name: "Offline smoke", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1")
      let service = CompanionInferenceService(connection: .init(name: "Controlled smoke", provider: "openai", route: .direct, modelID: model.id), credentials: SmokeCredentials(), transport: transport, model: model)
      let tools = #"[{"name":"write_file","description":"Write a test-only local file","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"read_file","description":"Read the test-only local file","parameters":{"type":"object","properties":{}},"replay":"safe"}]"#
      let config = PiDurableConfiguration(conversationID: "smoke-conversation", modelJSON: try model.descriptorJSON(), toolsJSON: tools)
      var eventCount = 0
      let runtime = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("runtime"), configuration: config,
        inference: { try await service.stream(requestJSON: $0, emit: $1) }, tool: { try await native.execute($0) }, onEvents: { _ in eventCount += 1 })
      _ = try await runtime.open()
      let receipt = try object(await runtime.submit(text: "Write and read the controlled native file", requestID: "smoke-stable-request"))
      guard let id = receipt["id"] as? Int else { throw CocoaError(.coderReadCorrupt) }
      let settled = try object(await runtime.wait(submissionID: id))
      guard settled["status"] as? String == "done" else { throw DeviceExecutionError.unavailable("Smoke submission did not finish: \(settled)") }
      let snapshot = try await runtime.snapshot()
      guard snapshot.contains("Verified the native iOS file: café 🟩") else { throw CocoaError(.coderReadCorrupt) }
      try await runtime.close()
      let reopened = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("runtime"), configuration: config,
        inference: { try await service.stream(requestJSON: $0, emit: $1) }, tool: { try await native.execute($0) })
      _ = try await reopened.open()
      let duplicate = try object(await reopened.submit(text: "Write and read the controlled native file", requestID: "smoke-stable-request"))
      let history = try object(await reopened.history())
      guard duplicate["id"] as? Int == id, duplicate["status"] as? String == "done", !(history["items"] as? [Any] ?? []).isEmpty else { throw CocoaError(.coderReadCorrupt) }
      try await reopened.close()
      let counts = (await transport.calls, await native.writes, await native.reads)
      guard counts == (3, 1, 1), eventCount > 0 else { throw DeviceExecutionError.unavailable("Duplicate native or inference work was detected.") }
      result.merge(["passed": true, "inferenceFixtureCalls": counts.0, "nativeWrites": counts.1, "nativeReads": counts.2,
        "sdkEventBatches": eventCount, "checkpointReopened": true, "submissionDeduplicated": true,
        "nativeFile": try String(contentsOf: root.appendingPathComponent("native-note.txt"), encoding: .utf8)]) { _, new in new }
      let codeTransport = SmokeInferenceTransport(codeMode: true)
      let codeNative = SmokeNativeTools(file: root.appendingPathComponent("code-note.txt"))
      let codeService = CompanionInferenceService(connection: .init(name: "Controlled code mode", provider: "openai", route: .direct, modelID: model.id), credentials: SmokeCredentials(), transport: codeTransport, model: model)
      let codeConfig = PiDurableConfiguration(conversationID: "smoke-code-conversation", modelJSON: try model.descriptorJSON(), toolsJSON: tools)
      func makeCodeRuntime() throws -> PiDurableRuntime {
        try PiDurableRuntime(storageDirectory: root.appendingPathComponent("code-runtime"), configuration: codeConfig,
          inference: { try await codeService.stream(requestJSON: $0, emit: $1) }, tool: { try await codeNative.execute($0) })
      }
      let codeRuntime = try makeCodeRuntime()
      _ = try await codeRuntime.open()
      let codeReceipt = try object(await codeRuntime.submit(text: "Use code mode and save JS state", requestID: "code-first"))
      guard let codeID = codeReceipt["id"] as? Int else { throw CocoaError(.coderReadCorrupt) }
      let codeSettled = try object(await codeRuntime.wait(submissionID: codeID))
      let firstCodeHistory = try await codeRuntime.snapshot()
      guard codeSettled["status"] as? String == "done", await codeNative.writes == 1, await codeNative.reads == 1,
            !firstCodeHistory.contains("isError\":true") else { throw DeviceExecutionError.unavailable("iOS code-mode native tool execution failed.") }
      try await codeRuntime.close()
      let restoredCode = try makeCodeRuntime()
      _ = try await restoredCode.open()
      let stateReceipt = try object(await restoredCode.submit(text: "Verify the saved JS state", requestID: "code-reopen"))
      guard let stateID = stateReceipt["id"] as? Int else { throw CocoaError(.coderReadCorrupt) }
      let stateSettled = try object(await restoredCode.wait(submissionID: stateID))
      let stateSnapshot = try await restoredCode.snapshot()
      guard stateSettled["status"] as? String == "done", stateSnapshot.contains("persisted JS state"),
            !stateSnapshot.contains("isError\":true"), await codeTransport.calls == 4 else { throw DeviceExecutionError.unavailable("iOS code-mode JavaScript state did not survive reopening.") }
      try await restoredCode.close()
      result["codeModeOnIOS"] = true; result["codeModeStateReopened"] = true
      result.merge(try await DeviceBackgroundSmoke.run(root: root, descriptor: model)) { _, new in new }
      // Exercise the app's packaged SwiftPM resources, without a test-only path override.
      let pythonWorkspace = root.appendingPathComponent("bundled-python")
      try FileManager.default.createDirectory(at: pythonWorkspace, withIntermediateDirectories: true)
      let python = try await EmbeddedCommandExecutor().run(.init(id: UUID(), argv: [
        "python", "-c", "import sqlite3; db=sqlite3.connect(':memory:'); print(db.execute('select 6*7').fetchone()[0])"
      ]), workspaceURL: pythonWorkspace) { _, _ in throw CocoaError(.featureUnsupported) }
      guard python.exitCode == 0, python.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "42" else {
        throw DeviceExecutionError.unavailable("The bundled iOS Python and SQLite runtime failed: \(python.stderr)")
      }
      result["bundledPythonOnIOS"] = true

    } catch { result["passed"] = false; result["error"] = error.localizedDescription }
    do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultFile, options: .atomic) }
    catch { NSLog("Device runtime smoke result could not be written: %@", error.localizedDescription) }
  }
  /// App-hosted UIKit coverage remains usable when the simulator XCTest
  /// service cannot start. The production renderer owns every rendered glyph.
  private static func selectableTable() throws -> [String: Any] {
    func require(_ value: Bool, _ message: String) throws {
      if !value { throw DeviceExecutionError.unavailable("Selectable table smoke: " + message) }
    }
    func scalars(_ text: String) -> [UInt32] {
      text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(\.value).sorted()
    }
    func largestFont(_ view: ConversationResponseNativeTextView) -> CGFloat {
      var maximum: CGFloat = 0
      view.textStorage.enumerateAttribute(.font, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
        if let font = value as? UIFont { maximum = max(maximum, font.pointSize) }
      }
      return maximum
    }
    let markdown = "| Left | Center | Right |\n| :--- | :---: | ---: |\n| **Bold** and [docs](https://example.com) | LongUnbrokenIdentifier0123456789🍎🍎🍎 | `code` and more words |"
    let expected = scalars("Left Center Right Bold and docs LongUnbrokenIdentifier0123456789🍎🍎🍎 code and more words")
    let view = ConversationResponseNativeTextView()
    var wide = CGSize.zero, narrow = CGSize.zero
    var regularFont: CGFloat = 0
    UITraitCollection(preferredContentSizeCategory: .large).performAsCurrent {
      view.apply(content: markdown, document: nil, isStreaming: false, typeSize: .large)
      wide = view.fittingSize(width: 600)
      narrow = view.fittingSize(width: 240)
      regularFont = largestFont(view)
    }
    try require(narrow.height > wide.height, "240-point layout did not wrap more than 600-point layout")
    try require(view.layoutManager.usedRect(for: view.textContainer).maxX <= 241, "wrapped glyphs exceeded the phone width")
    try require(scalars(view.text) == expected, "narrow layout changed or omitted cell text")
    var bold = false, code = false, link = false, alignments: [NSTextAlignment] = []
    var rows = 0
    view.textStorage.enumerateAttributes(in: NSRange(location: 0, length: view.textStorage.length)) { attributes, _, _ in
      if let font = attributes[.font] as? UIFont {
        bold = bold || font.fontDescriptor.symbolicTraits.contains(.traitBold)
        code = code || font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
      }
      link = link || (attributes[.link] as? URL)?.absoluteString == "https://example.com"
      if let style = attributes[.paragraphStyle] as? NSParagraphStyle { alignments = style.tabStops.map(\.alignment) }
    }
    view.textStorage.enumerateAttribute(.init("WovenMatterResponseTableRow"), in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
      if value != nil { rows += 1 }
    }
    try require(bold && code && link, "inline bold, code font, or link attributes were lost")
    try require(alignments == [.left, .center, .right] && rows == 2, "column alignment or row grid metadata was lost")
    try require(view.isSelectable && !view.isEditable && !view.isScrollEnabled, "table no longer shares the selectable transcript surface")
    view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
    try require(view.selectedRange.length == view.textStorage.length, "full-table native selection was incomplete")
    var restored = CGSize.zero
    UITraitCollection(preferredContentSizeCategory: .large).performAsCurrent { restored = view.fittingSize(width: 600) }
    try require(restored == wide && scalars(view.text) == expected, "widening the viewport did not restore the original layout")
    var accessibility = CGSize.zero, accessibilityFont: CGFloat = 0
    UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
      view.apply(content: markdown, document: nil, isStreaming: false, typeSize: .accessibility5)
      accessibility = view.fittingSize(width: 240)
      accessibilityFont = largestFont(view)
    }
    try require(accessibilityFont > regularFont && accessibility.height > narrow.height,
      "Dynamic Type did not remeasure enlarged rendered fonts")
    try require(scalars(view.text) == expected, "Dynamic Type changed or omitted cell text")
    try require(view.layoutManager.usedRect(for: view.textContainer).maxX <= 241, "Dynamic Type glyphs exceeded the phone width")
    return ["selectableTableOnIOS": true, "tableWideHeight": Double(wide.height), "tableNarrowHeight": Double(narrow.height),
      "tableAccessibilityHeight": Double(accessibility.height), "tableRegularFont": Double(regularFont), "tableAccessibilityFont": Double(accessibilityFont)]
  }
  private static func object(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
    return value
  }
}
#endif
