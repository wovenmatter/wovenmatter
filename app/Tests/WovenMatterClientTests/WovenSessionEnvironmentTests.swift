import Foundation
import Testing
@testable import WovenMatterClient

struct WovenSessionEnvironmentTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func macHelpersMatchTheLinuxHostHelpers() throws {
        let tools = Self.repository.appending(path: "remote/host/session-tools")
        #expect(try String(contentsOf: tools.appending(path: "sudo"), encoding: .utf8) == WovenSessionEnvironment.sudoScript)
        #expect(try String(contentsOf: tools.appending(path: "askpass"), encoding: .utf8) == WovenSessionEnvironment.askpassScript)
    }

    @Test func overlayPutsHelpersFirstAndDisablesPrompts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-session-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try #require(WovenSessionEnvironment.install(in: directory))
        for name in ["sudo", "askpass"] {
            #expect(FileManager.default.isExecutableFile(atPath: installed.appending(path: name).path))
        }
        var environment = ["PATH": installed.path + ":/usr/bin:/bin", "HOME": "/Users/fixture"]
        WovenSessionEnvironment.apply(to: &environment, toolsDirectory: installed, deviceName: "Mac Mini")
        let paths = try #require(environment["PATH"]).split(separator: ":").map(String.init)
        #expect(paths.first == installed.path && paths.filter { $0 == installed.path }.count == 1)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["SUDO_ASKPASS"] == installed.appending(path: "askpass").path)
        #expect(environment["WOVENMATTER_DEVICE_NAME"] == "Mac Mini")
        #expect(environment["HOME"] == "/Users/fixture")
    }

    /// A fake sudo stands in for the real one, so no test can ask for a password.
    @Test func passwordPromptFailsAtOnceWithTheDeviceName() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "woven-session-sudo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try #require(WovenSessionEnvironment.install(in: directory))
        let fake = directory.appending(path: "fake-sudo")
        try Data("#!/bin/sh\n[ \"$1\" = -n ] || exit 99\necho 'sudo: a password is required' >&2\nexit 1\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process(), errors = Pipe()
        process.executableURL = installed.appending(path: "sudo")
        process.arguments = ["/usr/bin/true"]
        process.environment = ["PATH": "/usr/bin:/bin", "WOVENMATTER_REAL_SUDO": fake.path, "WOVENMATTER_DEVICE_NAME": "Mac Mini"]
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 1)
        #expect(message.contains("This command needs Mac Mini's password"))
    }
}
