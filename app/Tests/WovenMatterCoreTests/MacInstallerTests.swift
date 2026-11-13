#if os(macOS)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore

struct MacInstallerTests {
    @Test(arguments: ["checksum", "signature", "replacement", "success", "unsupported-pairing", "busy-lock", "interrupt"])
    func stagedInstallerVerifiesBeforeReplacingAndRestoresOnFailure(_ scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woven-mac-installer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Woven Matter.app")
        let source = root.appendingPathComponent("candidate.app")
        for (path, version, build) in [(app, "0.3.2", "906"), (source, "0.3.6", "999")] {
            try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            var values: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleVersion": build, "LSMinimumSystemVersion": "26.0"]
            if path == source && scenario != "unsupported-pairing" { values["WovenMatterDeviceSetupVersion"] = 1 }
            let plist = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try plist.write(to: path.appendingPathComponent("Contents/Info.plist"))
        }
        try Data("old app".utf8).write(to: app.appendingPathComponent("old-marker"))
        try Data("new app".utf8).write(to: source.appendingPathComponent("new-marker"))
        let library = root.appendingPathComponent("library-data")
        try Data("preserved writing".utf8).write(to: library)
        func tool(_ name: String, _ body: String) throws -> String {
            let path = root.appendingPathComponent(name)
            try Data(("#!/bin/bash\nset -eu\n" + body).utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return RemoteWorkspaceExecTarget.quote(path.path)
        }
        let started = root.appendingPathComponent("download-started")
        let curl = try tool("curl", "touch \(RemoteWorkspaceExecTarget.quote(started.path))\n" + (scenario == "interrupt" ? "sleep 2\n" : "") + #"while [ "$1" != --output ]; do shift; done; printf payload > "$2""#)
        let hdiutil = try tool("hdiutil", """
            if [ "$1" = detach ]; then exit 0; fi
            while [ "$1" != -mountpoint ]; do shift; done
            /usr/bin/ditto \(RemoteWorkspaceExecTarget.quote(source.path)) "$2/Woven Matter.app"
            """)
        let signature = try tool("codesign", scenario == "signature" ? "exit 1" : "exit 0")
        let open = try tool("open", "printf opened > \(RemoteWorkspaceExecTarget.quote(root.appendingPathComponent("opened").path))")
        let pass = try tool("spctl", "exit 0")
        var script = MacRemoteScripts.install
            .replacingOccurrences(of: "lock_dir=\"$HOME/Library/Caches/WovenMatter/DeviceSetup\"", with: "lock_dir=" + RemoteWorkspaceExecTarget.quote(root.appendingPathComponent("lock").path))
            .replacingOccurrences(of: "app='/Applications/Woven Matter.app'", with: "app=" + RemoteWorkspaceExecTarget.quote(app.path))
            .replacingOccurrences(of: "$(uname -s)", with: "Darwin")
            .replacingOccurrences(of: "$(uname -m)", with: "arm64")
            .replacingOccurrences(of: "$(sw_vers -productVersion | cut -d. -f1)", with: "27")
            .replacingOccurrences(of: "$(stat -f %Su /dev/console)", with: "fixture")
            .replacingOccurrences(of: "$(id -un)", with: "fixture")
            .replacingOccurrences(of: "running() { /usr/bin/pgrep -f '[/]Woven Matter.app/Contents/MacOS/' >/dev/null 2>&1; }", with: "running() { return 1; }")
            .replacingOccurrences(of: "/usr/bin/curl", with: curl)
            .replacingOccurrences(of: "/usr/bin/hdiutil", with: hdiutil)
            .replacingOccurrences(of: "/usr/bin/codesign", with: signature)
            .replacingOccurrences(of: "/usr/sbin/spctl", with: pass)
            .replacingOccurrences(of: "/usr/bin/open", with: open)
        if scenario == "replacement" { script = script.replacingOccurrences(of: "mv \"$stage/Woven Matter.app\" \"$app\"", with: "false") }
        let lock = root.appendingPathComponent("lock/install.lock")
        if scenario == "busy-lock" {
            try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lock)
        }
        let hash = scenario == "checksum" ? String(repeating: "a", count: 64) : SHA256.hash(data: Data("payload".utf8)).hexString
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "--", "https://fixture.invalid/app.dmg", hash, "0.3.6", "999", try MacSetupRequest(action: .update).json(), "26.0", scenario == "unsupported-pairing" ? "1" : "0"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        if scenario == "interrupt" {
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: started.path), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(FileManager.default.fileExists(atPath: started.path))
            process.terminate()
        }
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(try Data(contentsOf: library) == Data("preserved writing".utf8))
        if scenario == "success" {
            #expect(process.terminationStatus == 0 && message.contains("installed"))
            #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("new-marker").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("opened").path))
        } else {
            #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("old-marker").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("opened").path))
            #expect(scenario == "replacement" || scenario == "interrupt" ? process.terminationStatus != 0 : message.hasPrefix("woven-error:"))
        }
        #expect(FileManager.default.fileExists(atPath: lock.path) == (scenario == "busy-lock"))
    }
}
#endif
