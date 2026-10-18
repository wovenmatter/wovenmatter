import Foundation
import CryptoKit
import WebKit

public struct EmbeddedCommandRequest: Codable, Sendable {
  public var id: UUID
  public var argv: [String]
  public var stdin: String
  public var workingDirectory: String
  public init(id: UUID, argv: [String], stdin: String = "", workingDirectory: String = "") {
    self.id = id; self.argv = argv; self.stdin = stdin; self.workingDirectory = workingDirectory
  }
}

public struct EmbeddedCommandResult: Codable, Sendable {
  public let requestID: UUID
  public let exitCode: Int
  public let stdout: String
  public let stderr: String
  public let stdoutPath: String
  public let stderrPath: String
  public let outputPreviewLimited: Bool
  public let changedFiles: [String]
  public let removedFiles: [String]
  public let runtime: String
}

public struct EmbeddedExecutionLimits: Sendable {
  public var workspaceBytes = 64 * 1024 * 1024
  public var workspaceEntries = 4096
  public var outputBytes = 64 * 1024 * 1024
  public var previewBytes = 32 * 1024
  public init() {}
}

private struct EmbeddedAcceptance: Codable {
  let requestDigest: String
  let acceptedAt: Date
}
private struct EmbeddedFailure: Codable {
  let requestDigest: String
  let status: String
  let message: String
  let finishedAt: Date
}

private struct EmbeddedReceipt: Codable {
  let requestDigest: String
  let result: EmbeddedCommandResult
}

/// Real, offline CPython 3.14 in an independently terminable WebAssembly worker.
/// Host storage and networking remain inaccessible; only explicit CLI calls cross
/// into native code. Each command snapshots its workspace and commits on completion.
@MainActor
public final class EmbeddedCommandExecutor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  public typealias CLI = @MainActor ([String], String) async throws -> String
  /// Identify only files explicitly created by this native CLI response (for
  /// example a library artifact), not arbitrary concurrent workspace changes.
  public typealias FileImports = @MainActor (_ arguments: [String], _ response: String) throws -> [String]
  public typealias Output = @MainActor (_ stream: String, _ text: String) -> Void
  private static var activeWorkspaces = Set<String>()
  private let resourceLocation: Result<URL, any Error>
  var resourceURL: URL { get throws { try resourceLocation.get() } }
  private let limits: EmbeddedExecutionLimits
  private var browser: WKWebView?
  private var continuation: CheckedContinuation<EmbeddedCommandResult, any Error>?
  private var request: EmbeddedCommandRequest?
  private var workspace: URL?
  private var snapshot: EmbeddedWorkspace?
  private var cli: CLI?
  private var output: Output?
  private var fileImports: FileImports?
  private var pending: [String: Task<Void, Never>] = [:]
  private var stdoutFile: FileHandle?
  private var stderrFile: FileHandle?
  private var stdoutPreview = Data(), stderrPreview = Data()
  private var outputBytes = 0
  private var started = false, finished = false
  private var requestDigest = ""
  private var setupWatchdog: Task<Void, Never>?

  public init(resourceURL: URL? = nil, limits: EmbeddedExecutionLimits = .init()) {
    #if SWIFT_PACKAGE
    let root = resourceURL ?? Bundle.module.resourceURL ?? Bundle.module.bundleURL
    #else
    let root = resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("EmbeddedResources")
    #endif
    self.resourceLocation = Result { try Self.locateResources(in: root) }
    self.limits = limits
    super.init()
  }

  static let requiredResources = ["worker.js", "commands.py", "python_stdlib.zip", "pyodide.asm.wasm", "pyodide-lock.json", "provenance.json"]

  static func locateResources(in root: URL) throws -> URL {
    // SwiftPM versions differ: resourceURL may already be the copied Resources
    // directory, or its parent. Require one complete local directory; never mix
    // files from layouts or fall back to a runtime download.
    for candidate in [root, root.appendingPathComponent("Resources", isDirectory: true)] {
      let complete = requiredResources.allSatisfy { name in
        let url = candidate.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
      }
      if complete { return candidate }
    }
    throw EmbeddedExecutionError.unavailable("The bundled Python runtime is incomplete. Reinstall this app build; no runtime files will be downloaded.")
  }

  /// A fresh executor owns one command. Replaying the same ID returns its durable
  /// receipt without repeating file mutations or native CLI calls.
  public func run(_ request: EmbeddedCommandRequest, workspaceURL: URL,
                  onOutput: Output? = nil, importFiles: FileImports? = nil, cli: @escaping CLI) async throws -> EmbeddedCommandResult {
    guard !started else { throw EmbeddedExecutionError.unavailable("Create a fresh executor for each command.") }
    started = true
    guard !request.argv.isEmpty, request.argv.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576,
          request.stdin.utf8.count <= limits.workspaceBytes else { throw EmbeddedExecutionError.unavailable("Invalid command arguments or input.") }
    if !request.workingDirectory.isEmpty { try EmbeddedWorkspace.validate(request.workingDirectory) }
    let root = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
    guard !Self.activeWorkspaces.contains(root.path) else { throw EmbeddedExecutionError.unavailable("Another command is using this workspace.") }
    try Task.checkCancellation()
    Self.activeWorkspaces.insert(root.path)
    defer { Self.activeWorkspaces.remove(root.path) }
    self.request = request; workspace = root; self.cli = cli; output = onOutput; fileImports = importFiles
    let requestEncoder = JSONEncoder(); requestEncoder.outputFormatting = [.sortedKeys]
    requestDigest = SHA256.hash(data: try requestEncoder.encode(request)).map { String(format: "%02x", $0) }.joined()
    let job = root.appendingPathComponent(EmbeddedWorkspace.metadataDirectory).appendingPathComponent(request.id.uuidString)
    for directory in [root.appendingPathComponent(EmbeddedWorkspace.metadataDirectory), job] {
      if FileManager.default.fileExists(atPath: directory.path) {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw EmbeddedExecutionError.unavailable("Invalid execution metadata directory.") }
      }
    }
    let receipt = job.appendingPathComponent("receipt.json")
    if FileManager.default.fileExists(atPath: receipt.path) {
      let saved = try JSONDecoder().decode(EmbeddedReceipt.self, from: Data(contentsOf: receipt))
      guard saved.requestDigest == requestDigest else { throw EmbeddedExecutionError.unavailable("The command ID was already used for different arguments.") }
      return saved.result
    }
    let accepted = job.appendingPathComponent("accepted.json")
    if FileManager.default.fileExists(atPath: accepted.path) {
      let saved = try JSONDecoder().decode(EmbeddedAcceptance.self, from: Data(contentsOf: accepted))
      guard saved.requestDigest == requestDigest else { throw EmbeddedExecutionError.unavailable("The command ID was already accepted with different arguments.") }
      throw EmbeddedExecutionError.unavailable("This command was previously accepted but has no completed receipt. Its native CLI calls may already have committed. Inspect .woven-execution/\(request.id.uuidString)/ before intentionally starting a new command; the script will not be replayed automatically.")
    }
    _ = try resourceURL
    snapshot = try EmbeddedWorkspace.read(root, maxBytes: limits.workspaceBytes, maxFiles: limits.workspaceEntries)
    if !request.workingDirectory.isEmpty, snapshot?.directories.contains(request.workingDirectory) != true {
      throw EmbeddedExecutionError.unavailable("Working directory does not exist in this workspace.")
    }
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    try JSONEncoder().encode(EmbeddedAcceptance(requestDigest:requestDigest,acceptedAt:Date())).write(to:accepted,options:.atomic)
    try EmbeddedWorkspace.synchronizeFile(accepted)
    try EmbeddedWorkspace.synchronizeDirectory(job)
    try EmbeddedWorkspace.synchronizeDirectory(job.deletingLastPathComponent())
    try EmbeddedWorkspace.synchronizeDirectory(root)
    for name in ["stdout.txt", "stderr.txt"] { try Data().write(to: job.appendingPathComponent(name), options: .atomic) }
    defer { try? stdoutFile?.close(); try? stderrFile?.close() }
    stdoutFile = try FileHandle(forWritingTo: job.appendingPathComponent("stdout.txt"))
    stderrFile = try FileHandle(forWritingTo: job.appendingPathComponent("stderr.txt"))
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "wovenEmbedded")
        let view = WKWebView(frame: .zero, configuration: config)
        browser = view; view.navigationDelegate = self
        view.loadHTMLString(Self.html, baseURL: nil)
        // Loading has a bounded watchdog; execution and awaited tools have no wall-clock deadline.
        setupWatchdog = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(90)) } catch { return }
          self?.finish(.failure(EmbeddedExecutionError.unavailable("The embedded Python runtime did not finish loading.")))
        }
      }
    } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
  }

  public func cancel() { finish(.failure(CancellationError())) }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !finished, let request, let snapshot else { return }
    do {
      let resourceURL = try self.resourceURL
      let worker = try String(contentsOf: resourceURL.appendingPathComponent("worker.js"), encoding: .utf8)
      let commands = try String(contentsOf: resourceURL.appendingPathComponent("commands.py"), encoding: .utf8)
      let lockfile = try String(contentsOf: resourceURL.appendingPathComponent("pyodide-lock.json"), encoding: .utf8)
      var assets: [String: String] = [:]
      for name in ["pyodide.asm.wasm", "python_stdlib.zip"] {
        assets[name] = try Data(contentsOf: resourceURL.appendingPathComponent(name)).base64EncodedString()
      }
      let payload: [String: Any] = ["type":"run", "argv":request.argv, "stdin":request.stdin,
        "workingDirectory":request.workingDirectory, "assets":assets, "lockfile":lockfile, "commands":commands,
        "files":snapshot.files.map { ["path":$0.key,"data":$0.value.base64EncodedString()] },
        "directories":Array(snapshot.directories), "maxWorkspaceBytes":limits.workspaceBytes,"maxFiles":limits.workspaceEntries]
      Task { [weak self] in
        do { _ = try await webView.callAsyncJavaScript("window.__wovenRun(worker, payload)", arguments: ["worker":worker,"payload":payload], in: nil, contentWorld: .page) }
        catch { self?.finish(.failure(error)) }
      }
    } catch { finish(.failure(error)) }
  }

  public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !finished, message.name == "wovenEmbedded", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    do {
      switch type {
      case "ready": setupWatchdog?.cancel(); setupWatchdog = nil
      case "output":
        guard let stream = body["stream"] as? String, let text = body["text"] as? String, ["stdout","stderr"].contains(stream) else { throw EmbeddedExecutionError.unavailable("Invalid command output.") }
        let data = Data(text.utf8); outputBytes += data.count
        guard outputBytes <= limits.outputBytes else { throw EmbeddedExecutionError.unavailable("Command output exceeded the configured \(limits.outputBytes)-byte budget. Output produced before cancellation is saved in the job files.") }
        if stream == "stdout" { try stdoutFile?.write(contentsOf: data); stdoutPreview.append(data.prefix(max(0,limits.previewBytes-stdoutPreview.count))) }
        else { try stderrFile?.write(contentsOf: data); stderrPreview.append(data.prefix(max(0,limits.previewBytes-stderrPreview.count))) }
        output?(stream,text)
      case "cli":
        guard let id = body["id"] as? String, let sequence = UInt64(id), let request, let cli,
              pending[id] == nil, pending.count < 32,
              let arguments = body["argumentsJSON"] as? String, arguments.utf8.count <= 32 * 1_048_576,
              let argv = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String] else {
          throw EmbeddedExecutionError.unavailable("Invalid native CLI request.")
        }
        let stableID = Self.commandID(request: request.id, sequence: sequence)
        pending[id] = Task { [weak self] in
          let response: [String: Any]
          do {
            let json = try await cli(argv, stableID)
            try Task.checkCancellation()
            guard let self, !self.finished else { return }
            let paths = try self.fileImports?(argv, json) ?? []
            let files = try self.importWorkspaceFiles(paths)
            response = ["id":id,"ok":true,"value":json,"files":files]
          }
          catch { response = ["id":id,"ok":false,"error":error.localizedDescription] }
          guard let self, !self.finished else { return }
          self.pending.removeValue(forKey: id)
          do { _ = try await self.browser?.callAsyncJavaScript("window.__wovenReply(response)", arguments: ["response":response], in: nil, contentWorld: .page) }
          catch { self.finish(.failure(error)) }
        }
      case "done": try complete(body)
      case "failure": throw EmbeddedExecutionError.unavailable(body["message"] as? String ?? "Embedded execution failed.")
      default: throw EmbeddedExecutionError.unavailable("Unknown worker message.")
      }
    } catch { finish(.failure(error)) }
  }

  private func importWorkspaceFiles(_ paths: [String]) throws -> [[String: String]] {
    guard !paths.isEmpty else { return [] }
    guard let workspace, var baseline = snapshot else { throw CancellationError() }
    guard Set(paths).count == paths.count else { throw EmbeddedExecutionError.unavailable("Duplicate imported artifact paths.") }
    let host = try EmbeddedWorkspace.read(workspace,maxBytes:limits.workspaceBytes,maxFiles:limits.workspaceEntries)
    var imported: [[String:String]] = []
    for path in paths {
      try EmbeddedWorkspace.validate(path)
      guard baseline.files[path] == nil, !baseline.directories.contains(path), let data = host.files[path] else {
        throw EmbeddedExecutionError.unavailable("Native CLI imports must identify new, regular workspace files.")
      }
      baseline.files[path] = data
      var parent = (path as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard baseline.files[parent] == nil, host.directories.contains(parent) else { throw EmbeddedExecutionError.unavailable("Invalid imported artifact directory.") }
        baseline.directories.insert(parent); parent = (parent as NSString).deletingLastPathComponent
      }
      imported.append(["path":path,"data":data.base64EncodedString()])
    }
    // Only those explicitly imported new paths advance the baseline. An unrelated
    // native edit still differs at final commit and rejects the virtual result.
    snapshot = baseline
    return imported
  }

  private func complete(_ body: [String: Any]) throws {
    guard let request, let workspace, let snapshot, pending.isEmpty,
          let code = body["exitCode"] as? Int, let files = body["files"] as? [[String: Any]], let directories = body["directories"] as? [String] else {
      throw EmbeddedExecutionError.unavailable("Invalid embedded command result.")
    }
    let resultFiles = try EmbeddedWorkspace.decode(files: files, directories: directories, maxBytes: limits.workspaceBytes, maxFiles: limits.workspaceEntries)
    let prefix = "\(EmbeddedWorkspace.metadataDirectory)/\(request.id.uuidString)/"
    let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceURL.appendingPathComponent("provenance.json"))) as? [String: Any]
    guard let pythonVersion = provenance?["pythonVersion"] as? String,
          let pyodideVersion = provenance?["version"] as? String else {
      throw EmbeddedExecutionError.unavailable("The bundled Python runtime provenance is incomplete.")
    }
    let result = EmbeddedCommandResult(requestID: request.id, exitCode: code,
      stdout: String(decoding:stdoutPreview,as:UTF8.self), stderr:String(decoding:stderrPreview,as:UTF8.self),
      stdoutPath:prefix+"stdout.txt",stderrPath:prefix+"stderr.txt",
      outputPreviewLimited:outputBytes > stdoutPreview.count + stderrPreview.count,
      changedFiles:resultFiles.files.keys.filter { resultFiles.files[$0] != snapshot.files[$0] }.sorted(),
      removedFiles:snapshot.files.keys.filter { resultFiles.files[$0] == nil }.sorted(), runtime:"CPython \(pythonVersion) / Pyodide \(pyodideVersion)")
    try stdoutFile?.synchronize(); try stderrFile?.synchronize()
    try stdoutFile?.close(); stdoutFile = nil; try stderrFile?.close(); stderrFile = nil
    let receipt = try JSONEncoder().encode(EmbeddedReceipt(requestDigest:requestDigest,result:result))
    try resultFiles.commit(to: workspace, replacing:snapshot, receipt:receipt, requestID:request.id, maxBytes:limits.workspaceBytes,maxFiles:limits.workspaceEntries)
    finish(.success(result))
  }

  static func commandID(request: UUID, sequence: UInt64) -> String {
    let bytes = Array(SHA256.hash(data: Data("\(request.uuidString):wovenmatter:\(sequence)".utf8)).prefix(16))
    let hex = bytes.map { String(format:"%02x",$0) }.joined()
    return [String(hex.prefix(8)),String(hex.dropFirst(8).prefix(4)),String(hex.dropFirst(12).prefix(4)),String(hex.dropFirst(16).prefix(4)),String(hex.dropFirst(20))].joined(separator:"-")
  }
  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(EmbeddedExecutionError.unavailable("The isolated Python process was interrupted. Uncommitted workspace changes were not applied."))) }
  public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
  private func finish(_ result: Result<EmbeddedCommandResult, any Error>) {
    guard !finished else { return }; finished = true
    if case let .failure(error) = result, let workspace, let request {
      let failure = EmbeddedFailure(requestDigest:requestDigest,status:error is CancellationError ? "cancelled" : "failed",message:error.localizedDescription,finishedAt:Date())
      let path = workspace.appendingPathComponent(EmbeddedWorkspace.metadataDirectory).appendingPathComponent(request.id.uuidString).appendingPathComponent("failure.json")
      try? JSONEncoder().encode(failure).write(to:path,options:.atomic)
    }
    setupWatchdog?.cancel(); setupWatchdog = nil
    for task in pending.values { task.cancel() }; pending.removeAll()
    try? stdoutFile?.close(); try? stderrFile?.close(); stdoutFile = nil; stderrFile = nil
    browser?.evaluateJavaScript("window.__wovenStop()",completionHandler:nil)
    browser?.stopLoading(); browser?.configuration.userContentController.removeScriptMessageHandler(forName:"wovenEmbedded")
    browser?.navigationDelegate = nil; browser = nil; cli = nil; output = nil; fileImports = nil
    let continuation = self.continuation; self.continuation = nil; continuation?.resume(with:result)
  }
  private static let html = #"""
  <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><script>
  (() => {
    let worker;
    window.__wovenStop = () => { worker?.terminate(); worker = null; };
    window.__wovenReply = response => worker?.postMessage({type:'reply',...response});
    window.__wovenRun = (source,payload) => {
      const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));
      worker=new Worker(url); URL.revokeObjectURL(url);
      worker.onmessage=event=>window.webkit.messageHandlers.wovenEmbedded.postMessage(event.data);
      worker.onerror=event=>window.webkit.messageHandlers.wovenEmbedded.postMessage({type:'failure',message:event.message||'Embedded worker failed.'});
      worker.postMessage(payload);
    };
  })();
  </script>
  """#
}
