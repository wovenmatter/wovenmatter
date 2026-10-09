import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterDashboardStore

struct OpenCodeStableCompatibilityTests {
    @Test func compatibilityAcceptsFutureV2ReleasesAndRejectsOtherMajors() {
        for version in ["2.0.0", "2.0.22", "2.99.1", "2.1.0-beta.1", "2.1.0+build.7"] {
            #expect(OpenCodeConnection.supportsVersion(version))
        }
        for version in ["1.18.29", "3.0.0", "0.0.0-beta-19278", "2", "2.0", "2.0.0garbage", ""] {
            #expect(!OpenCodeConnection.supportsVersion(version))
        }
    }

    @Test func installerResolvesTheCurrentReleaseAgainForEachOperation() async throws {
        let installer = LocalACPRuntimeInstaller()
        let first = try await installer.prepareCLIInstall(OpenCodeServiceLauncher.installDefinition, fetch: { url in
            #expect(url.path.hasSuffix("/latest"))
            return Data(#"{"version":"2.0.22","bin":{"opencode":"bin/opencode"}}"#.utf8)
        })
        let next = try await installer.prepareCLIInstall(OpenCodeServiceLauncher.installDefinition, fetch: { _ in
            Data(#"{"version":"2.1.7","bin":{"opencode":"bin/opencode"}}"#.utf8)
        })
        #expect(first.packageSpec == "@opencode/cli@2.0.22")
        #expect(next.packageSpec == "@opencode/cli@2.1.7")
        await #expect(throws: OpenCodeError.incompatible("1.18.29")) {
            try await installer.prepareCLIInstall(OpenCodeServiceLauncher.installDefinition, fetch: { _ in
                Data(#"{"version":"1.18.29","bin":{"opencode":"bin/opencode"}}"#.utf8)
            })
        }
    }

    @Test func discoveryPrefersV2AliasOverV1CanonicalCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["opencode", "opencode2"] {
            let file = directory.appending(path: command)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [directory.path])
        #expect(OpenCodeServiceLauncher.resolveExecutable(resolver: resolver, probe: {
            $0.lastPathComponent == "opencode" ? "1.18.29" : "opencode2 v2.1.0"
        })?.lastPathComponent == "opencode2")
        #expect(OpenCodeServiceLauncher.resolveExecutable(resolver: resolver, probe: { _ in "2.99.0" })?.lastPathComponent == "opencode")
    }

    @Test func hiddenFormFieldsUseServerDefaultsAndDriveVisibleConditions() throws {
        let fields: [OpenCodeValue] = [
            ["key": "context", "type": "string", "hidden": .bool(true), "default": "fixed"],
            ["key": "answer", "type": "string", "when": .array([["key": "context", "op": "eq", "value": "fixed"]])]
        ]
        let answers: [String: OpenCodeValue] = ["context": "stale", "answer": "yes"]
        #expect(OpenCodeFormAnswers.activeFields(fields, answers: answers).count == 2)
        let reply = try OpenCodeFormAnswers.reply(fields: fields, answers: answers)
        #expect(reply["context"].text == "fixed")
        #expect(reply["answer"].text == "yes")
    }

    // Opt-in, provider-free contract test using an isolated official v2 binary.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_OPENCODE_TEST_EXECUTABLE"] != nil))
    func stableServiceContract() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WOVENMATTER_OPENCODE_TEST_EXECUTABLE"]))
        let root = FileManager.default.temporaryDirectory.appending(path: "opencode-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--service", "--hostname", "127.0.0.1"]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "OPENCODE_TEST_HOME": root.path, "TMPDIR": root.path,
            "XDG_STATE_HOME": root.appending(path: "state").path,
            "XDG_CONFIG_HOME": root.appending(path: "config").path, "XDG_DATA_HOME": root.appending(path: "data").path,
            "XDG_CACHE_HOME": root.appending(path: "cache").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        let registration = root.appending(path: "state/opencode/service.json")
        var found: OpenCodeConnection?
        for _ in 0..<120 {
            if let connection = try? OpenCodeConnection.discover(file: registration),
               (try? await OpenCodeHTTPClient(connection: connection).health()) != nil { found = connection; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let connection = try #require(found)
        let client = OpenCodeHTTPClient(connection: connection)
        #expect(OpenCodeConnection.supportsVersion(try await client.health()["version"].text))
        let reused = try await OpenCodeServiceLauncher.ensure(executable: nil, registration: registration)
        #expect(reused == connection)
        let created = try await client.call("POST", "/api/session", body: ["location": ["directory": .string(root.path)], "title": "Provider-free contract test"])
        let sessionID = try #require(created["data"]["id"].string)
        let path = "/api/session/" + OpenCodeHTTPClient.segment(sessionID)
        let form = try await client.call("POST", path + "/form", body: ["title": "Question", "fields": .array([["key": "answer", "type": "string", "title": "Answer"]])])
        let formID = try #require(form["data"]["id"].string)
        let formPath = path + "/form/" + OpenCodeHTTPClient.segment(formID)
        #expect(try await client.call("GET", formPath)["data"]["state"]["status"].text == "pending")
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let coordinator = OpenCodeSessionCoordinator(database: database)
        try await coordinator.connect(connection)
        let conversationID = try await database.createLocalACPSession(runtimeKind: .opencode, title: "Fixture", ownerDeviceID: UUID(), openCodeAssociation: (connection.identity, sessionID))
        let link = OpenCodeSessionLink(conversationID: conversationID, connectionID: connection.identity, sessionID: sessionID)
        try await coordinator.refresh(link)
        let pending = try await database.openCodeSnapshot(conversationID: conversationID)
        #expect(pending?.forms.first?["id"].text == formID)
        _ = try await client.call("DELETE", formPath)
        #expect(try await client.call("GET", formPath)["data"]["state"]["status"].text == "cancelled")
        try await coordinator.refresh(link)
        let cancelled = try await database.openCodeSnapshot(conversationID: conversationID)
        #expect(cancelled?.forms.isEmpty == true)
        await coordinator.shutdown()
        _ = try await client.call("DELETE", path)
        try await OpenCodeServiceLauncher.stop(registration: registration)
    }
}
