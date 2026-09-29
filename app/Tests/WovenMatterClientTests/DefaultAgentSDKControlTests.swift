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

    @Test func timeoutReapsOnlyItsOwnedProcessGroup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = Process()
        unrelated.executableURL = URL(filePath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
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
        let operation = Task {
            try await DefaultAgentSDKControl.run(.init(action: .check, id: "pi"), executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", hangingScript, "fixture", root.path], timeout: 30)
        }
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
        import json, os, signal, sys, time
        root, mode = sys.argv[1:]
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(root + '/child', 'w') as output: output.write(str(os.getpid()))
            while os.path.isdir(root): time.sleep(0.01)
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(root + '/parent', 'w') as output: output.write(str(os.getpid()))
        print(json.dumps({'result': {'sdks': [], 'generation': 'confirmed-installed'}}), flush=True)
        if mode == 'exit': os._exit(0)
        while True: time.sleep(0.01)
        """#
        let start = ContinuousClock.now
        let result = try await DefaultAgentSDKControl.run(.init(action: .update, id: "claude"),
            executable: URL(filePath: "/usr/bin/python3"), arguments: ["-c", script, root.path, mode], timeout: 0.1)
        #expect(result.generation == "confirmed-installed")
        #expect(start.duration(to: .now) < .seconds(5))
        try assertReaped(root.appending(path: "parent"))
        // It deliberately remains alive until fixture cleanup removes its directory.
        let child = try #require(Int32(String(contentsOf: root.appending(path: "child"), encoding: .utf8)))
        #expect(kill(child, 0) == 0)
    }
}
