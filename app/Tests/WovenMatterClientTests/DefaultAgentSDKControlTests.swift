import Darwin
import Foundation
import Testing

@testable import WovenMatterClient

@Suite("SDK maintenance process ownership")
struct DefaultAgentSDKControlTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: "woven-sdk-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func awaitFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { throw DefaultAgentError.message("Fixture did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func startFixture(
        _ run: @escaping @Sendable () async throws -> DefaultAgentSDKStatus
    ) async -> Task<DefaultAgentSDKStatus, any Error> {
        let admitted = AsyncStream<Void>.makeStream()
        let operation = Task {
            // Swift Testing can queue this task behind unrelated test work.
            // Start the fixture deadline only once this task actually runs.
            admitted.continuation.yield(())
            admitted.continuation.finish()
            return try await run()
        }
        for await _ in admitted.stream { break }
        return operation
    }
    private func awaitReady(_ root: URL, operation: Task<DefaultAgentSDKStatus, any Error>) async throws {
        do { try await awaitFile(root.appending(path: "ready")) }
        catch {
            operation.cancel()
            let outcome: String
            switch await operation.result {
            case .success(let result): outcome = "returned generation \(result.generation ?? "nil")"
            case .failure(let failure): outcome = "failed: \(failure.localizedDescription)"
            }
            let phases = ["launch", "interpreter", "parent", "child", "ready"].filter {
                FileManager.default.fileExists(atPath: root.appending(path: $0).path)
            }.joined(separator: ", ")
            let stderr = (try? String(contentsOf: root.appending(path: "stderr"), encoding: .utf8)) ?? ""
            throw DefaultAgentError.message("Fixture did not become ready; phases=[\(phases)]; \(outcome); stderr=\(stderr.prefix(2048))")
        }
    }
    private func assertReaped(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    private let hangingScript = #"""
    trap '' TERM
    printf '%s' "$$" > "$1/parent"
    /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$1/child"; while :; do /bin/sleep 1; done' fixture "$1" &
    while :; do wait; done
    """#

    @Test @MainActor
    func maintenanceStartsWhenGlobalUtilityPoolIsSaturated() async throws {
        let pressure = UtilityPoolPressure()
        defer { pressure.release() }
        #expect(pressure.probeRemainsQueued())
        let result = try await DefaultAgentSDKControl.run(.init(action: .status),
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", #"printf '%s\n' '{"result":{"sdks":[],"generation":"owned-thread"}}'"#],
            timeout: 1)
        #expect(result.generation == "owned-thread")
        // A watchdog eventually releases pressure to keep a broken implementation
        // from hanging this suite. It must not be needed for maintenance to run.
        #expect(pressure.probeRemainsQueued())
    }

    @Test func cancellationBeforeExecutionStartsDoesNotSpawnAHelper() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DefaultAgentSDKControl.run(.init(action: .status),
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf started > \"$1/parent\"", "fixture", root.path], timeout: 1)
        }
        do { _ = try await operation.value; Issue.record("Cancelled maintenance unexpectedly ran") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "parent").path))
    }

    @Test func timeoutReapsOnlyItsOwnedProcessGroup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = Process()
        let unrelatedInput = Pipe()
        unrelated.executableURL = URL(filePath: "/bin/cat")
        unrelated.standardInput = unrelatedInput
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer {
            try? unrelatedInput.fileHandleForWriting.close()
            unrelated.waitUntilExit()
        }
        do {
            _ = try await DefaultAgentSDKControl.run(.init(action: .status), executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", hangingScript, "fixture", root.path], timeout: 0.5)
            Issue.record("A timed out fixture must not return an SDK status")
        } catch { #expect(error.localizedDescription.contains("Reload installed versions")) }
        try assertReaped(root.appending(path: "parent"))
        let child = try String(contentsOf: root.appending(path: "child"), encoding: .utf8)
        let childPID = try #require(Int32(child))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(childPID, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
        #expect(unrelated.isRunning)
    }

    @Test func taskCancellationTerminatesTheHelper() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = await startFixture {
            try await DefaultAgentSDKControl.run(.init(action: .check, id: "pi"), executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", hangingScript, "fixture", root.path], timeout: 30)
        }
        defer { operation.cancel() }
        try await awaitFile(root.appending(path: "child"))
        operation.cancel()
        do { _ = try await operation.value; Issue.record("A canceled fixture must not return an SDK status") }
        catch { #expect(error.localizedDescription.contains("Reload installed versions")) }
        try assertReaped(root.appending(path: "parent"))
    }

    @Test func aConfirmedActivationWinsOverLateCancellation() async throws {
        let script = #"""
        trap '' TERM
        printf '%s\n' '{"result":{"sdks":[],"generation":"confirmed-installed"}}'
        while :; do /bin/sleep 1; done
        """#
        let result = try await DefaultAgentSDKControl.run(.init(action: .update, id: "claude"),
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], timeout: 0.1)
        #expect(result.generation == "confirmed-installed")
    }
}


extension DefaultAgentSDKControlTests {
    @Test(arguments: ["exit", "wait"])
    func escapedDescendantCannotHoldTheResponsePipeOpen(mode: String) async throws {
        let root = try directory()
        // The escaped fixture watches this private directory and exits when it
        // disappears. Cleanup never signals a PID after its ownership can change.
        defer { try? FileManager.default.removeItem(at: root) }
        let script = #"""
        import sys
        root, mode = sys.argv[1:]
        with open(root + '/interpreter', 'w') as output: output.write('started')
        import json, os, signal, time
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(root + '/child', 'w') as output: output.write(str(os.getpid()))
            while os.path.isdir(root): time.sleep(0.01)
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(root + '/parent', 'w') as output: output.write(str(os.getpid()))
        while not os.path.isfile(root + '/child'): time.sleep(0.01)
        print(json.dumps({'result': {'sdks': [], 'generation': 'confirmed-installed'}}), flush=True)
        with open(root + '/ready', 'w') as output: output.write('ready')
        if mode == 'exit': os._exit(0)
        while True: time.sleep(0.01)
        """#
        let launch = #"""
        printf started > "$1/launch"
        exec /usr/bin/python3 -c "$2" "$1" "$3" 2>"$1/stderr"
        """#
        let operation = await startFixture {
            try await DefaultAgentSDKControl.run(.init(action: .update, id: "claude"),
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", launch, "fixture", root.path, script, mode], timeout: 30)
        }
        defer { operation.cancel() }
        // This checks pipe teardown after a confirmed result, not Python's
        // cold startup speed. Timeout behavior has its own shell fixture above.
        try await awaitReady(root, operation: operation)
        let start = ContinuousClock.now
        if mode == "wait" { operation.cancel() }
        let result = try await operation.value
        #expect(result.generation == "confirmed-installed")
        #expect(start.duration(to: .now) < .seconds(5))
        try assertReaped(root.appending(path: "parent"))
        // It deliberately remains alive until fixture cleanup removes its directory.
        let child = try #require(Int32(String(contentsOf: root.appending(path: "child"), encoding: .utf8)))
        #expect(kill(child, 0) == 0)
    }
}

private final class UtilityPoolPressure: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let jobs = DispatchGroup()
    private let watchdog = DispatchSemaphore(value: 0)
    private let released = NSLock()
    private var isReleased = false
    let probe = DispatchSemaphore(value: 0)
    private let count = 256

    init() {
        for _ in 0..<count {
            jobs.enter()
            DispatchQueue.global(qos: .utility).async { [gate, jobs] in
                gate.wait()
                jobs.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async { [probe] in probe.signal() }
        let recovery = Thread { [weak self, watchdog] in
            if watchdog.wait(timeout: .now() + .seconds(5)) == .timedOut {
                self?.release()
            }
        }
        recovery.start()
    }

    func probeRemainsQueued() -> Bool {
        probe.wait(timeout: .now()) == .timedOut
    }

    func release() {
        guard released.withLock({
            if isReleased { return false }
            isReleased = true
            return true
        }) else { return }
        watchdog.signal()
        for _ in 0..<count { gate.signal() }
        jobs.wait()
    }
}
