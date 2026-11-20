import Foundation

/// A browser, computer-use or HTML-preview tool call this Mac's server asks a
/// connected UI to carry out. macOS ties those permissions to the app window,
/// so the server forwards them here (ARCHITECTURE: the Woven MCP).
struct AutomationRequest: Sendable {
    /// Unique per call; a repeated ID returns the saved or running result.
    let requestID: String
    /// The session that made the call.
    let callerID: String
    let group: WorkspaceToolGroup
    let action: Action
    /// False when an earlier UI already admitted this request: its input is
    /// never replayed.
    let admitted: Bool

    enum Action: Sendable, Equatable {
        /// Run the tool with its JSON input.
        case call(json: String)
        /// Cancel one running call by its request ID, or every call of the caller.
        case cancel(target: String)
        static let cancelAll = "all"
    }
}

/// What the UI answers to an `AutomationRequest`.
struct AutomationResponse: Sendable, Equatable {
    var success = true
    var result: JSONValue?
    var error: String?
    var code: String?
    var requestID: String?

    static let maximumResponseBytes = 1_048_576

    /// The same encoded-byte ceiling every tool response has.
    func bounded() -> Self {
        let size = result.flatMap { try? JSONEncoder().encode($0).count } ?? 0
        guard size <= Self.maximumResponseBytes else {
            return Self(success: false,
                error: "The response exceeds 1 MiB. Retry reads with a smaller limit or characters value.",
                code: "response_too_large", requestID: requestID)
        }
        return self
    }
}

/// Carries out browser, computer-use and HTML-preview calls in this app. One
/// call runs at a time; a repeated request ID returns the running or saved result.
@MainActor
final class WovenAutomationHost {
    static let maximumHTMLRequestBytes = 40 * 1_024 * 1_024

    private struct Identity: Hashable {
        let group: WorkspaceToolGroup
        let callerID: String
        let input: String
    }
    private struct Running { let caller: String; let identity: Identity; let task: Task<AutomationResponse, Never> }
    private let assets: WorkspaceAssetSession
    private let computer = WovenComputerAutomation()
    private var running: [String: Running] = [:]
    private var completed: [String: (Identity, AutomationResponse)] = [:]
    private var completionOrder: [String] = []

    init(assets: WorkspaceAssetSession) {
        self.assets = assets
    }

    /// Stops every running call, for when the connection to the server ends.
    func stop() { running.values.forEach { $0.task.cancel() }; running.removeAll(); computer.revokeAll() }

    func cancel(callerID: String) async {
        let calls = running.values.filter { $0.caller == callerID }
        for call in calls { call.task.cancel() }
        computer.revoke(callerID: callerID)
        for call in calls { _ = await call.task.value }
    }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        let id = request.requestID
        do {
            guard UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("Invalid automation request ID.") }
            let group = request.group
            guard group.isAutomation else { throw WorkspaceToolError.invalid("Invalid automation group.") }
            let json: String
            switch request.action {
            case .cancel(let target):
                if target == AutomationRequest.Action.cancelAll { await cancel(callerID: request.callerID) }
                if let call = running[target], call.caller == request.callerID { call.task.cancel(); _ = await call.task.value }
                computer.revoke(callerID: request.callerID)
                return .init(requestID: id)
            case .call(let input):
                json = input
            }
            let identity = Identity(group: group, callerID: request.callerID, input: json)
            if let saved = completed[id] {
                guard identity == saved.0 else { throw WorkspaceToolError.invalid("Automation request identity changed.") }
                return saved.1
            }
            if let saved = running[id] {
                guard identity == saved.identity else { throw WorkspaceToolError.invalid("Automation request identity changed.") }
                return await saved.task.value
            }
            guard request.admitted else { throw WorkspaceToolError.invalid("This request was already admitted by an earlier host. Inspect the current state; input was not replayed.") }
            guard running.isEmpty else { throw WorkspaceToolError.invalid("Another agent is using the browser or computer. Wait for it to finish, then inspect fresh state.") }
            let limit = group == .html ? Self.maximumHTMLRequestBytes : 3 * 1024 * 1024
            guard json.utf8.count <= limit else { throw WorkspaceToolError.invalid("Automation input exceeds its size limit.") }
            let input = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            let task = Task { @MainActor [self] () -> AutomationResponse in
                do {
                    let admit: @MainActor @Sendable () async throws -> Void = { try Task.checkCancellation() }
                    try await admit()
                    let result: JSONValue
                    switch group {
                    case .html: result = try await ConversationHTMLPreview().capture(input)
                    case .computer: result = try await computer.execute(input, callerID: request.callerID, admit: admit)
                    default: result = try await browser(input, admit: admit)
                    }
                    try await admit()
                    return .init(result: result, requestID: id)
                } catch {
                    return .init(success: false, error: Task.isCancelled ? "Automation interrupted. Inspect fresh state before repeating input." : error.localizedDescription,
                                 code: Task.isCancelled ? "cancelled" : "automation_failed", requestID: id)
                }
            }
            running[id] = .init(caller: request.callerID, identity: identity, task: task)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(25))
                if !Task.isCancelled { task.cancel() }
            }
            let result = await task.value.bounded()
            deadline.cancel()
            running[id] = nil; completed[id] = (identity, result); completionOrder.append(id)
            if completionOrder.count > 16 { completed.removeValue(forKey: completionOrder.removeFirst()) }
            return result
        } catch { return .init(success: false, error: error.localizedDescription, code: "automation_unavailable", requestID: id) }
    }
    private func browser(_ input: JSONValue, admit: @MainActor @escaping () async throws -> Void) async throws -> JSONValue {
        guard let args = input.objectValue, let action = args["action"]?.stringValue else { throw WorkspaceToolError.invalid("Provide a browser action.") }
        let keys: Set<String> = ["action", "tabId", "frame", "url", "selector", "text", "key", "x", "y", "button", "clickCount", "destination", "code", "value", "checked", "accept", "name", "mimeType", "data", "id", "offset"]
        guard Set(args.keys).isSubset(of: keys) else { throw WorkspaceToolError.invalid("Unknown browser parameter.") }
        try await admit()
        if !["tabs", "snapshot", "screenshot", "downloads", "read-download"].contains(action) { computer.revokeAll() }
        if action == "tabs" { return try .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: JSONEncoder().encode(assets.automationTabs), as: UTF8.self))])])]) }
        if action == "open" {
            let url = args["url"]?.stringValue ?? "about:blank"
            guard let destination = BrowserAddress.destination(for: url) else { throw WorkspaceToolError.invalid("Use an HTTP(S) browser URL.") }
            guard let page = assets.openBrowser(url: destination.absoluteString), let id = assets.pages.first(where: { $0.value === page })?.key else { throw WorkspaceToolError.invalid(assets.notice ?? "The browser could not open a tab.") }
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("tabId: " + id.uuidString.lowercased())])])])
        }
        guard let raw = args["tabId"]?.stringValue, let id = UUID(uuidString: raw), let page = assets.pages[id], !page.closed else { throw WorkspaceToolError.invalid("Choose a current tabId from tabs or open.") }
        if action == "focus" { assets.focusAutomationBrowser(id); return .object(["focused": .bool(true)]) }
        if action == "close" { assets.close(.browser(id)); return .object(["closed": .bool(true)]) }
        if action == "downloads" { return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: page.automationDownloads)) }
        if action == "read-download" {
            guard let downloadID = args["id"]?.stringValue, let offset = (args["offset"] ?? .number(0)).intValue,
                offset >= 0, let value = page.readAutomationDownload(downloadID, offset: UInt(offset)) else { throw WorkspaceToolError.invalid("Choose a completed download ID and valid byte offset.") }
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let runner = WovenBrowserActionProcess()
        return try await runner.run(page: page, id: id, input: input, admit: admit)
    }
}

/// A bounded per-action helper with joined cleanup. Its only native authority
/// is the exact page passed by the app; the model supplies no endpoint or paths.
@MainActor
private final class WovenBrowserActionProcess {
    private var child: Process?
    private var writer: FileHandle?
    private var waiter: CheckedContinuation<JSONValue, any Error>?
    private var page: WMBrowserPage?
    private var admit: (@MainActor () async throws -> Void)?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var outcome: Result<JSONValue, any Error>?

    /// The bundled Node runtime that also carries the browser helper script.
    private static var helperResources: URL? {
        Bundle.main.resourceURL.map { $0.appending(path: "default-agent") }.flatMap {
            FileManager.default.fileExists(atPath: $0.appending(path: "src/browser-runtime.mjs").path) ? $0 : nil
        }
    }

    /// One read of whatever bytes are available; empty at end of file.
    /// `FileHandle.read(upToCount:)` would wait to fill its whole count.
    nonisolated private static func readAvailable(_ handle: FileHandle, maximum: Int = 65_536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    func run(page: WMBrowserPage, id: UUID, input: JSONValue,
             admit: @MainActor @escaping () async throws -> Void) async throws -> JSONValue {
        guard let root = Self.helperResources else { throw WorkspaceToolError.invalid("The bundled browser helper is unavailable.") }
        self.page = page; self.admit = admit
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = root.appending(path: "bin/node")
        process.arguments = [root.appending(path: "src/browser-runtime.mjs").path]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        child = process; writer = stdin.fileHandleForWriting
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.completeAfterExit() }
        }
        page.automationMessageHandler = { [weak self] message in
            guard let self, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)) else { return }
            self.send(.object(["native": json]))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                do {
                    try process.run()
                    send(.object(["target": .object(["id": .string(id.uuidString.lowercased()), "url": .string(page.url), "title": .string(page.title)]), "version": .string(page.chromiumVersion), "input": input]))
                    let output = stdout.fileHandleForReading
                    Thread { [weak self] in
                        var pending = Data()
                        do {
                            while case let bytes = try Self.readAvailable(output), !bytes.isEmpty {
                                pending.append(bytes)
                                guard pending.count <= 8 * 1024 * 1024 else { throw WorkspaceToolError.invalid("Browser protocol response exceeds 8 MiB.") }
                                while let newline = pending.firstIndex(of: 10) {
                                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                                    let packet = try JSONDecoder().decode(JSONValue.self, from: line)
                                    DispatchQueue.main.async { self?.receive(packet) }
                                }
                            }
                            DispatchQueue.main.async { self?.finish(.failure(WorkspaceToolError.invalid("Browser helper disconnected."))) }
                        } catch { DispatchQueue.main.async { self?.finish(.failure(error)) } }
                    }.start()
                    deadline = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(25))
                        if !Task.isCancelled { self?.finish(.failure(WorkspaceToolError.invalid("Browser action timed out. Inspect state before retrying input."))) }
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func receive(_ packet: JSONValue) {
        guard !finished, let object = packet.objectValue else { return }
        if let result = object["result"] { finish(.success(result)); return }
        if let error = object["error"]?.stringValue { finish(.failure(WorkspaceToolError.invalid(error))); return }
        if let cdp = object["cdp"] {
            Task { @MainActor [weak self] in
                guard let self, !finished else { return }
                do {
                    try await admit?()
                    guard !finished else { return }
                    let json = String(decoding: try JSONEncoder().encode(cdp), as: UTF8.self)
                    guard page?.sendAutomationMessage(json) == true else { throw WorkspaceToolError.invalid("The embedded page is closed or not ready. Inspect tabs and retry after loading.") }
                } catch { finish(.failure(error)) }
            }
        }
    }
    private func send(_ value: JSONValue) {
        guard !finished else { return }
        do { try writer?.write(contentsOf: JSONEncoder().encode(value) + Data([10])) }
        catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<JSONValue, any Error>) {
        guard !finished else { return }; finished = true
        outcome = result
        deadline?.cancel(); page?.detachAutomation(); try? writer?.close()
        if let child, child.isRunning { child.terminate(); return }
        completeAfterExit()
    }
    private func completeAfterExit() {
        guard finished, let result = outcome else { return }
        let continuation = waiter; waiter = nil
        continuation?.resume(with: result)
    }
}
