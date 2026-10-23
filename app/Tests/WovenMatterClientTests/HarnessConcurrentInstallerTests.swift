import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HarnessConcurrentInstallerTests {
    @Test func differentHarnessesInstallTogetherWhileSameHarnessIsLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-concurrency-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let npm = root.appending(path: "npm")
        try Data(#"""
        #!/bin/sh
        fixture_root="$(dirname "$0")"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--prefix' ]; then shift; prefix="$1"; fi
          package="$1"
          shift
        done
        case "$package" in
          @fixture/one@*) name=one; other=two ;;
          @fixture/two@*) name=two; other=one ;;
          *) exit 3 ;;
        esac
        touch "$fixture_root/$name.started"
        count=0
        while [ ! -f "$fixture_root/$other.started" ]; do
          count=$((count + 1))
          if [ "$count" -gt 100 ]; then exit 4; fi
          sleep 0.1
        done
        mkdir -p "$prefix/bin"
        printf '#!/bin/sh\necho 1.2.3\n' > "$prefix/bin/$name"
        chmod 700 "$prefix/bin/$name"
        """#.utf8).write(to: npm)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: npm.path)
        let installer = LocalACPRuntimeInstaller(installPrefix: root.appending(path: "managed"), npmExecutableURL: npm,
            metadataFetcher: { _ in Data(#"{"version":"1.2.3","bin":{"fixture":"bin.js"}}"#.utf8) })
        func definition(_ kind: AgentRuntimeKind, _ name: String) -> LocalACPRuntimeDefinition {
            .init(runtimeKind: kind, displayName: name, commandName: name, arguments: [], underlyingCLIName: nil,
                cliInstallerSource: nil, cliInstallerInterpreter: nil, adapterPackage: "@fixture/" + name,
                adapterDescription: "Fixture")
        }
        let one = definition(.codex, "one"), two = definition(.claudeCode, "two")
        let first = Task { try await installer.install(one, component: .adapter) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: root.appending(path: "one.started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "one.started").path))
        await #expect(throws: RuntimeMaintenanceError.busy) { try await installer.install(one, component: .adapter) }
        let second = try await installer.install(two, component: .adapter)
        let firstURL = try await first.value
        #expect(FileManager.default.isExecutableFile(atPath: firstURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: second.path))
        #expect(firstURL.resolvingSymlinksInPath().deletingLastPathComponent() != second.resolvingSymlinksInPath().deletingLastPathComponent())
    }
}


extension HarnessConcurrentInstallerTests {
    @Test func separateInstallersShareOneVerifiedNodeBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "node-concurrency-\(UUID())")
        let bin = root.appending(path: "archive/node/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["node", "npm"] {
            let executable = bin.appending(path: name)
            try Data("#!/bin/sh\necho v99.0.0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let archive = root.appending(path: "node.tar.gz")
        let packed = try LocalACPProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", archive.path, "-C", root.appending(path: "archive").path, "node"])
        #expect(packed.succeeded)
        let data = try Data(contentsOf: archive)
        let artifact = LocalACPManagedNodeArtifact(version: "v99.0.0", platform: "fixture", archiveFileName: "node.tar.gz",
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let downloads = FixtureNodeDownloads(data: data)
        let destination = root.appending(path: "managed")
        let first = LocalACPManagedNodeRuntime(rootDirectory: destination, artifact: artifact, downloader: { _ in try await downloads.fetch() })
        let second = LocalACPManagedNodeRuntime(rootDirectory: destination, artifact: artifact, downloader: { _ in try await downloads.fetch() })
        async let one = first.ensureInstalled()
        async let two = second.ensureInstalled()
        let (oneURL, twoURL) = try await (one, two)
        #expect(oneURL == twoURL)
        #expect(FileManager.default.isExecutableFile(atPath: oneURL.path))
        #expect(await downloads.count == 1)
    }
}

private actor FixtureNodeDownloads {
    let data: Data
    var count = 0
    init(data: Data) { self.data = data }
    func fetch() async throws -> Data {
        count += 1
        try await Task.sleep(for: .milliseconds(100))
        return data
    }
}
