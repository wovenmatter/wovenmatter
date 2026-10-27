import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HarnessConcurrentInstallerTests {
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
