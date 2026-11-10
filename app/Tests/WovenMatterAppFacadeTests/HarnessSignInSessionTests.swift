#if os(macOS)
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Runs sign-in sessions against fake harness commands. Nothing contacts a provider.
@MainActor @Suite(.serialized) struct HarnessSignInSessionTests {
    private func fakeCommand(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harness-sign-in-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-harness")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func showsTheLinkAndCodeThenSendsThePagesCode() async throws {
        let (directory, executable) = try fakeCommand("""
            printf 'Open this link in your browser\\n   https://example.test/device\\n'
            printf 'Enter this one-time code\\n   ABCD-EFGH\\n'
            read reply
            [ "$reply" = "page-code#state" ] || exit 3
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let method = HarnessSignInFlow.Method(id: "test", title: "Sign in", arguments: [],
                                              input: .codeFromPage(label: "Code"))
        let session = HarnessSignInSession(kind: .claudeCode, method: method)
        var exited: Bool?
        session.run(executable: executable, environment: ProcessInfo.processInfo.environment, key: nil) { exited = $0 }
        try await waitUntil { session.code != nil }
        #expect(session.state == .waiting)
        #expect(session.url?.absoluteString == "https://example.test/device")
        #expect(session.code == "ABCD-EFGH")
        session.send("page-code#state")
        try await waitUntil { exited != nil }
        #expect(exited == true)
        session.succeed()
        #expect(session.state == .succeeded)
    }

    @Test func aKeyIsSentBeforeTheCommandFinishes() async throws {
        let (directory, executable) = try fakeCommand("""
            read key
            [ "$key" = "sk-test-key" ] || exit 4
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let method = HarnessSignInFlow.Method(id: "key", title: "Use a key", arguments: [],
                                              input: .keyBeforeStart(label: "Key"))
        let session = HarnessSignInSession(kind: .codex, method: method)
        var exited: Bool?
        session.run(executable: executable, environment: ProcessInfo.processInfo.environment, key: "  sk-test-key \n") { exited = $0 }
        try await waitUntil { exited != nil || session.state == .failed }
        #expect(exited == true)
    }

    @Test func cancelStopsAWaitingCommandAndAFailureSaysSo() async throws {
        let (directory, executable) = try fakeCommand("printf 'https://example.test/wait\\n'; sleep 30\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = HarnessSignInSession(kind: .grokBuild,
            method: .init(id: "device", title: "Sign in", arguments: []))
        session.run(executable: executable, environment: ProcessInfo.processInfo.environment, key: nil) { _ in }
        try await waitUntil { session.url != nil }
        session.cancel()
        try await waitUntil { session.state == .cancelled }
        #expect(session.state == .cancelled)

        let (failingDirectory, failing) = try fakeCommand("exit 2\n")
        defer { try? FileManager.default.removeItem(at: failingDirectory) }
        let failed = HarnessSignInSession(kind: .codex, method: .init(id: "device", title: "Sign in", arguments: []))
        var exited = false
        failed.run(executable: failing, environment: ProcessInfo.processInfo.environment, key: nil) { _ in exited = true }
        try await waitUntil { failed.state == .failed }
        #expect(failed.state == .failed)
        #expect(!exited)
        #expect(failed.message.contains("Sign-in didn't finish"))
    }
}
#endif
