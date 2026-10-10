import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Hosts model inference for authorized mobile clients. Pi's agent and all tools stay on the requesting device.
@MainActor
final class CompanionInferenceHost {
    typealias Prepare = @MainActor @Sendable () async throws -> Data
    typealias Run = @Sendable (Data, @escaping @Sendable (Data) async throws -> Void) async throws -> Void
    private let preparePayload: Prepare
    private let injectedRun: Run?
    private let authentication: CompanionExecutionAuthentication
    private let descriptor: CompanionExecutionWorkspace
    private let directory: URL
    private let isActive: @MainActor @Sendable () -> Bool
    init(authentication: CompanionExecutionAuthentication, descriptor: CompanionExecutionWorkspace, directory: URL,
         isActive: @escaping @MainActor @Sendable () -> Bool,
         preparePayload: @escaping Prepare = { try await ProviderAccountCoordinator.shared.prepare("local").data() },
         run: Run? = nil) {
        self.authentication = authentication; self.descriptor = descriptor; self.directory = directory; self.isActive = isActive
        self.preparePayload = preparePayload; self.injectedRun = run
    }
    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard isActive() else { return .error("unavailable", "This inference host is stopped.", status: 503) }
        do {
            let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            let catalog = request.method == "GET" && ["/v1/inference/catalog", "/wovenmatter/v1/inference/catalog"].contains(path)
            let stream = request.method == "POST" && ["/v1/inference/stream", "/wovenmatter/v1/inference/stream"].contains(path)
            guard catalog || stream else { return .error("not_found", "Unknown inference endpoint.", status: 404) }
            guard let bearer = request.bearer else { return .error("unauthorized", "An authorized inference-host connection is required.", status: 401) }
            let scope = try await authentication.authenticate(bearer: bearer)
            guard scope.libraryID == descriptor.libraryID, scope.workspaceID == descriptor.id,
                  request.headers["x-woven-protocol"] == String(CompanionProtocol.version),
                  request.headers["x-woven-library"] == scope.libraryID,
                  request.headers["x-woven-workspace"] == scope.workspaceID,
                  request.headers["x-woven-device"] == scope.deviceID else {
                return .error("wrong_workspace", "This inference credential is scoped to another device or workspace.", status: 403)
            }
            guard request.body.count <= 8 * 1024 * 1024 else { return .error("too_large", "Inference input exceeds the request limit.", status: 413) }
            var object: [String: Any] = [:]
            if catalog, let provider = URLComponents(string: "http://localhost" + request.target)?.queryItems?.first(where: { $0.name == "provider" })?.value {
                object["provider"] = provider
            }
            if stream {
                guard let value = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                    return .error("invalid_request", "Invalid inference request.", status: 400)
                }
                object = value
            }
            // This is the existing credential owner and refresh coordinator. Credentials cross only private stdin.
            let payload = try await preparePayload()
            guard isActive() else { return .error("unavailable", "This inference host stopped.", status: 503) }
            let configured = try JSONSerialization.jsonObject(with: payload)
            let body = try JSONSerialization.data(withJSONObject: ["action": catalog ? "catalog" : "stream",
                "payload": configured, "request": object, "principalID": scope.deviceID])
            let run: Run
            if let injectedRun { run = injectedRun }
            else {
                guard let launch = DefaultAgentSupport.resolution().launchConfiguration else {
                    return .error("unavailable", "The bundled Pi Durable inference helper is unavailable.", status: 503)
                }
                let helper = CompanionInferenceProcess(executable: launch.executableURL, arguments: launch.arguments, directory: directory)
                run = { body, emit in try await helper.run(body: body, emit: emit) }
            }
            if catalog {
                let collected = CompanionInferenceBytes()
                try await run(body) { data in try collected.append(data) }
                return CompanionHTTPResponse(body: collected.data)
            }
            let model = object["model"] as? [String: Any] ?? [:]
            let provider = model["provider"] as? String ?? "", modelID = model["id"] as? String ?? ""
            return CompanionHTTPResponse(contentType: "application/x-ndjson", stream: { emit in
                do { try await run(body, emit) }
                catch {
                    try Task.checkCancellation()
                    let message = (error as? CompanionInferenceHostError)?.message ?? "The inference host could not complete this request. Saved agent work remains on your device."
                    let result: [String: Any] = ["type": "error", "reason": "error", "error": ["role": "assistant",
                        "api": "woven-inference-host", "provider": provider, "model": modelID, "content": [],
                        "timestamp": Int(Date().timeIntervalSince1970 * 1000), "stopReason": "error", "errorMessage": message,
                        "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]]]
                    var line = try JSONSerialization.data(withJSONObject: result); line.append(10); try await emit(line)
                }
            })
        } catch let error as CompanionAPIError {
            return .error(error.code, error.message, status: error.code == "unauthorized" ? 401 : 503)
        } catch {
            return .error("inference_unavailable", "The Mac inference connection is unavailable. Check its connection in Settings.", status: 503)
        }
    }
}

private struct CompanionInferenceHostError: Error, Sendable { let message: String }
private final class CompanionInferenceBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func append(_ data: Data) throws {
        try lock.withLock {
            guard stored.count + data.count <= 4 * 1024 * 1024 else { throw CompanionInferenceHostError(message: "The inference catalog exceeded its size limit.") }
            stored.append(data)
        }
    }
}

/// A pipe naturally applies backpressure while a socket write is pending. No credential material reaches logging.
final class CompanionInferenceProcess: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    init(executable: URL, arguments: [String], directory: URL) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
    }
    private func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            lock.withLock { if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        }
    }
    func run(body: Data, emit: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                let child = Process(), input = Pipe(), output = Pipe()
                child.executableURL = URL(fileURLWithPath: "/bin/sh")
                child.arguments = ["-c", #"ulimit -c 0; exec "$@""#, "woven-inference", executable.path] + arguments + ["--inference"]
                child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["WOVEN_INFERENCE_DIRECTORY"] = directory.appendingPathComponent("inference-host", isDirectory: true).path
                child.environment = environment
                try lock.withLock {
                    guard !cancelled else { throw CancellationError() }
                    process = child; try child.run()
                }
                let deadline = DispatchWorkItem { [self] in cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1800, execute: deadline)
                defer {
                    deadline.cancel()
                    if child.isRunning { cancel() }
                    try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
                }
                let wire = body + Data([10])
                // Read and write different pipes concurrently: a large prompt must not deadlock against stderr/stdout.
                let writer = Task.detached {
                    try input.fileHandleForWriting.write(contentsOf: wire)
                    try input.fileHandleForWriting.close()
                }
                var pending = Data(), count = 0
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    // FileHandle.read(upToCount:) may wait to fill its buffer on a pipe. POSIX read
                    // returns each available chunk so token output is delivered before process exit.
                    let received = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if received == 0 { break }
                    if received < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    let bytes = Data(buffer.prefix(received))
                    if lock.withLock({ cancelled }) { throw CancellationError() }
                    count += bytes.count; guard count <= 32 * 1024 * 1024 else { throw CompanionInferenceHostError(message: "The inference response exceeded its size limit.") }
                    pending.append(bytes)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CompanionInferenceHostError(message: "The inference helper returned an invalid response.") }
                        if value["type"] as? String == "host_error" { throw CompanionInferenceHostError(message: value["message"] as? String ?? "Inference failed.") }
                        var framed = line; framed.append(10)
                        for offset in stride(from: 0, to: framed.count, by: 65536) { try await emit(Data(framed[offset..<min(offset + 65536, framed.count)])) }
                    }
                    guard pending.count <= 4 * 1024 * 1024 else { throw CompanionInferenceHostError(message: "An inference event exceeded its size limit.") }
                }
                try await writer.value
                child.waitUntilExit()
                if lock.withLock({ cancelled }) { throw CancellationError() }
                guard pending.isEmpty, child.terminationStatus == 0 else { throw CompanionInferenceHostError(message: "The inference helper stopped before completing its response.") }
                lock.withLock { process = nil }
            }.value
        } onCancel: { [self] in cancel() }
    }
}
