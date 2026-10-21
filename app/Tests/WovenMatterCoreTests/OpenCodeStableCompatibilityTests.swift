import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterDashboardStore

struct OpenCodeStableCompatibilityTests {

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
        try await database.saveSessionExecutionRoot(id: conversationID, folderID: nil,
            location: .init(workspaceID: "device:" + UUID().uuidString.lowercased(), rootPath: root.path, managed: false),
            defaultPath: root.path)
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
