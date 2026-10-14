#if COMPANION_FACADE_TESTS
import CompanionBrowserTestBridge
#endif
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
import WovenMatterAutomation

/// The visible app owns CEF and TCC grants. Background/remote runtimes reach
/// this host through their already-scoped CLI service, never a raw CDP endpoint.
@MainActor
final class WovenAutomationHost {
    private let assets: WorkspaceAssetSession
    private let database: WorkspaceDatabase
    private let computer = WovenComputerAutomation()
    private struct Running { let caller: String; let identity: BackendRPCCommandIdentity; let task: Task<WovenMatterToolResponse, Never> }
    private var running: [String: Running] = [:]
    private var completed: [String: (BackendRPCCommandIdentity, WovenMatterToolResponse)] = [:]
    private var completionOrder: [String] = []
    private var server: BackendRPCServer?

    init(assets: WorkspaceAssetSession, database: WorkspaceDatabase) { self.assets = assets; self.database = database }
    func start(at url: URL) throws {
        let service = BackendRPCServer(socketURL: url)
        try service.start { [weak self] request in
            guard let self else { return BackendRPCResponse(id: request.id, error: "The automation host closed.") }
            do {
                guard request.method == "automation.call" else { throw WorkspaceToolError.invalid("Invalid automation request.") }
                let invocation = try JSONDecoder().decode(WovenAutomationInvocation.self, from: request.payload)
                let result = await self.handle(invocation)
                return BackendRPCResponse(id: request.id, result: try JSONEncoder().encode(result.bounded()))
            } catch { return BackendRPCResponse(id: request.id, error: error.localizedDescription) }
        }
        server = service
    }
    func stop() { server?.stop(); server = nil; running.values.forEach { $0.task.cancel() }; running.removeAll(); computer.revokeAll() }
    func cancel(callerID: String) async {
        let calls = running.values.filter { $0.caller == callerID }
        for call in calls { call.task.cancel() }
        computer.revoke(callerID: callerID)
        for call in calls { _ = await call.task.value }
    }
    func handle(_ invocation: WovenAutomationInvocation) async -> WovenMatterToolResponse {
        let id = invocation.request.requestID
        do {
            guard UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("Invalid automation request ID.") }
            let command = try WovenMatterToolCommand(invocation.request.arguments)
            guard command.options["image"] == nil else { throw WorkspaceToolError.invalid("Image paths must be handled on the CLI host.") }
            guard let group = command.group, [.browser, .computer].contains(group) else { throw WorkspaceToolError.invalid("Invalid automation group.") }
            if command.action == "cancel" {
                let target = try command.required("id")
                if target == "all" { await cancel(callerID: invocation.callerID) }
                if let call = running[target], call.caller == invocation.callerID { call.task.cancel(); _ = await call.task.value }
                computer.revoke(callerID: invocation.callerID)
                return .init()
            }
            try await database.requireTool(group, sessionID: invocation.callerID)
            let identity = BackendRPCCommandIdentity(.init(method: group.rawValue + ":" + invocation.callerID,
                payload: try JSONEncoder().encode(invocation.request.operationArguments)))
            if let saved = completed[id] {
                guard identity == saved.0 else { throw WorkspaceToolError.invalid("Automation request identity changed.") }
                return saved.1
            }
            if let saved = running[id] {
                guard identity == saved.identity else { throw WorkspaceToolError.invalid("Automation request identity changed.") }
                return await saved.task.value
            }
            guard invocation.admitted else { throw WorkspaceToolError.invalid("This request was already admitted by an earlier host. Inspect the current state; input was not replayed.") }
            guard running.isEmpty else { throw WorkspaceToolError.invalid("Another agent is using the browser or computer. Wait for it to finish, then inspect fresh state.") }
            let json = try command.required("json")
            guard json.utf8.count <= 3 * 1024 * 1024 else { throw WorkspaceToolError.invalid("Automation input exceeds 3 MiB.") }
            let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(json.utf8))
            let task = Task { @MainActor [self] () -> WovenMatterToolResponse in
                do {
                    let admit: @MainActor @Sendable () async throws -> Void = { @MainActor [database] in
                        try Task.checkCancellation()
                        try await database.requireAutomationRequest(group, callerID: invocation.callerID, requestID: id)
                        try await database.requireCompanionAutomationAccess(callerID: invocation.callerID)
                        try Task.checkCancellation()
                    }
                    let result = group == .computer
                        ? try await computer.execute(input, callerID: invocation.callerID, admit: admit)
                        : try await browser(input, admit: admit)
                    try await admit()
                    return .init(result: result, requestID: id)
                } catch {
                    return .init(success: false, error: Task.isCancelled ? "Automation interrupted. Inspect fresh state before repeating input." : error.localizedDescription,
                                 code: Task.isCancelled ? "cancelled" : "automation_failed", requestID: id)
                }
            }
            running[id] = .init(caller: invocation.callerID, identity: identity, task: task)
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
    private func browser(_ input: GatewayJSONValue, admit: @MainActor @escaping () async throws -> Void) async throws -> GatewayJSONValue {
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
        if action == "downloads" { return try JSONDecoder().decode(GatewayJSONValue.self, from: JSONSerialization.data(withJSONObject: page.automationDownloads)) }
        if action == "read-download" {
            guard let downloadID = args["id"]?.stringValue, let offset = (args["offset"] ?? .number(0)).intValue,
                offset >= 0, let value = page.readAutomationDownload(downloadID, offset: UInt(offset)) else { throw WorkspaceToolError.invalid("Choose a completed download ID and valid byte offset.") }
            return try JSONDecoder().decode(GatewayJSONValue.self, from: JSONSerialization.data(withJSONObject: value))
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
    private var waiter: CheckedContinuation<GatewayJSONValue, any Error>?
    private var page: WMBrowserPage?
    private var admit: (@MainActor () async throws -> Void)?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var outcome: Result<GatewayJSONValue, any Error>?
    func run(page: WMBrowserPage, id: UUID, input: GatewayJSONValue,
             admit: @MainActor @escaping () async throws -> Void) async throws -> GatewayJSONValue {
        guard let root = DefaultAgentSupport.resources else { throw WorkspaceToolError.invalid("The bundled browser helper is unavailable.") }
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
            guard let self, let json = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(message.utf8)) else { return }
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
                            while let bytes = try output.read(upToCount: 65536), !bytes.isEmpty {
                                pending.append(bytes)
                                guard pending.count <= 8 * 1024 * 1024 else { throw WorkspaceToolError.invalid("Browser protocol response exceeds 8 MiB.") }
                                while let newline = pending.firstIndex(of: 10) {
                                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                                    let packet = try JSONDecoder().decode(GatewayJSONValue.self, from: line)
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
    private func receive(_ packet: GatewayJSONValue) {
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
    private func send(_ value: GatewayJSONValue) {
        guard !finished else { return }
        do { try writer?.write(contentsOf: JSONEncoder().encode(value) + Data([10])) }
        catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<GatewayJSONValue, any Error>) {
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
