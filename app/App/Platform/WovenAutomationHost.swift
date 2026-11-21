import Foundation
import WovenProtocol

/// Carries out the Woven MCP's `browser` and `computer` tools, which this Mac's
/// server asks its UI to do because macOS ties those permissions to the app
/// (ARCHITECTURE: the Woven MCP). One call runs at a time.
@MainActor
final class WovenAutomationHost {
    static let maximumResultBytes = 1_048_576

    private let assets: WorkspaceAssetSession
    private let computer = WovenComputerAutomation()
    private var busy = false

    init(assets: WorkspaceAssetSession) {
        self.assets = assets
    }

    func handle(_ call: UIToolCall) async -> ToolResult {
        guard !busy else { return .error("Another agent is using the browser or computer. Wait for it to finish, then inspect fresh state.") }
        busy = true
        defer { busy = false }
        // Each session gets its own Cua connection, closed when it goes idle.
        let caller = call.sessionID ?? "woven"
        let task = Task { @MainActor [self] () -> ToolResult in
            do {
                let result: JSONValue
                switch call.tool {
                case "browser": result = try await browser(call.arguments)
                case "computer": result = try await computer.execute(call.arguments, callerID: caller)
                default: return .error("Unknown tool \(call.tool).")
                }
                try Task.checkCancellation()
                return Self.toolResult(result)
            } catch {
                return .error(Task.isCancelled ? "Automation interrupted. Inspect fresh state before repeating input." : error.localizedDescription)
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { task.cancel() }
        }
        let result = await task.value
        deadline.cancel()
        let size = (try? JSONEncoder().encode(result).count) ?? 0
        guard size <= Self.maximumResultBytes else {
            return .error("The response exceeds 1 MiB. Retry reads with a smaller limit or characters value.")
        }
        return result
    }

    /// A result with a `content` array of MCP blocks keeps its blocks; any
    /// other JSON is one text block of that JSON.
    static func toolResult(_ value: JSONValue) -> ToolResult {
        guard let object = value.objectValue, let blocks = object["content"]?.array else {
            return .text(json(value))
        }
        let content = blocks.map { block -> ToolContent in
            let fields = block.objectValue
            switch fields?["type"]?.string {
            case "text": return .text(fields?["text"]?.string ?? "")
            case "image":
                if let data = fields?["data"]?.string, let mimeType = fields?["mimeType"]?.string {
                    return .image(data: data, mimeType: mimeType)
                }
                return .text(json(block))
            default: return .text(json(block))
            }
        }
        return ToolResult(content: content, isError: object["isError"]?.bool ?? false)
    }

    private static func json(_ value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func browser(_ input: JSONValue) async throws -> JSONValue {
        guard let args = input.objectValue, let action = args["action"]?.string else { throw WorkspaceToolError.invalid("Provide a browser action.") }
        let keys: Set<String> = ["action", "tabId", "frame", "url", "selector", "text", "key", "x", "y", "button", "clickCount", "destination", "code", "value", "checked", "accept", "name", "mimeType", "data", "id", "offset"]
        guard Set(args.keys).isSubset(of: keys) else { throw WorkspaceToolError.invalid("Unknown browser parameter.") }
        try Task.checkCancellation()
        // Browser input and desktop input never run together.
        if !["tabs", "snapshot", "screenshot", "downloads", "read-download"].contains(action) { computer.revokeAll() }
        if action == "tabs" { return .array(assets.automationTabs) }
        if action == "open" {
            let url = args["url"]?.string ?? "about:blank"
            guard let destination = BrowserAddress.destination(for: url) else { throw WorkspaceToolError.invalid("Use an HTTP(S) browser URL.") }
            guard let page = assets.openBrowser(url: destination.absoluteString), let id = assets.pages.first(where: { $0.value === page })?.key else { throw WorkspaceToolError.invalid(assets.notice ?? "The browser could not open a tab.") }
            return .object(["tabId": .string(id.uuidString.lowercased())])
        }
        guard let raw = args["tabId"]?.string, let id = UUID(uuidString: raw), let page = assets.pages[id], !page.closed else { throw WorkspaceToolError.invalid("Choose a current tabId from tabs or open.") }
        if action == "focus" { assets.focusAutomationBrowser(id); return .object(["focused": .bool(true)]) }
        if action == "close" { assets.close(.browser(id)); return .object(["closed": .bool(true)]) }
        if action == "downloads" { return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: page.automationDownloads)) }
        if action == "read-download" {
            guard let downloadID = args["id"]?.string, let offset = (args["offset"] ?? .number(0)).int,
                offset >= 0, let value = page.readAutomationDownload(downloadID, offset: UInt(offset)) else { throw WorkspaceToolError.invalid("Choose a completed download ID and valid byte offset.") }
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        }
        return try await WovenBrowserActionProcess().run(page: page, id: id, input: input)
    }
}

/// Runs one browser action through the bundled helper, which drives the page
/// with Playwright over CDP that this process relays to CEF. Its only native
/// authority is the exact page passed here; the agent supplies no endpoint or paths.
@MainActor
private final class WovenBrowserActionProcess {
    private var child: Process?
    private var writer: FileHandle?
    private var waiter: CheckedContinuation<JSONValue, any Error>?
    private var page: WMBrowserPage?
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

    func run(page: WMBrowserPage, id: UUID, input: JSONValue) async throws -> JSONValue {
        guard let root = Self.helperResources else { throw WorkspaceToolError.invalid("The bundled browser helper is unavailable.") }
        self.page = page
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
        if let error = object["error"]?.string { finish(.failure(WorkspaceToolError.invalid(error))); return }
        if let cdp = object["cdp"] {
            do {
                let json = String(decoding: try JSONEncoder().encode(cdp), as: UTF8.self)
                guard page?.sendAutomationMessage(json) == true else { throw WorkspaceToolError.invalid("The embedded page is closed or not ready. Inspect tabs and retry after loading.") }
            } catch { finish(.failure(error)) }
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
