import Foundation
import CryptoKit
import Testing
@testable import WovenMatterClient

@Suite("Release updates")
struct ReleaseUpdateTests {

  @Test("rejects a release that requires a newer macOS")
  func rejectsUnsupportedSystem() async throws {
    let futureManifest = validManifest.replacingOccurrences(
      of: "\"minimum_macos\": \"26.0\"",
      with: "\"minimum_macos\": \"27.0\""
    )
    let client = WovenMatterReleaseUpdateClient(
      fetch: { url in
        let response = try #require(HTTPURLResponse(
          url: url,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        ))
        return (Data(futureManifest.utf8), response)
      },
      currentOperatingSystemVersion: {
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
      }
    )
    await #expect(throws: WovenMatterReleaseUpdateError.unsupportedSystem(minimumMacOS: "27.0")) {
      try await client.check(currentVersion: "0.0.9")
    }
  }


  @Test("checks an official update, rejects invalid payloads, and caches a verified download")
  func checksAndDownloadsOnlyVerifiedOfficialRelease() async throws {
    let payload = Data("signed release payload".utf8)
    let digest = SHA256.hash(data: payload)
      .map { String(format: "%02x", $0) }
      .joined()
    let manifestData = Data(validManifest.replacingOccurrences(
        of: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        with: digest
      ).utf8)
    let verifiedManifest = try JSONDecoder().decode(WovenMatterReleaseManifest.self, from: manifestData)
    let client = WovenMatterReleaseUpdateClient { url in
      let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
      return (manifestData, response)
    }
    guard case .available(let available) = try await client.check(currentVersion: "0.0.9") else {
      Issue.record("Expected an available release"); return
    }
    #expect(available == verifiedManifest)
    #expect(available.version == "0.1.0")
    #expect(try available.validated() == available)
    let invalid = try JSONDecoder().decode(WovenMatterReleaseManifest.self,
      from: Data(validManifest.replacingOccurrences(of: "WovenMatter_0.1.0_arm64.dmg", with: "WovenMatter_0.1.0_x64.dmg").utf8))
    #expect(throws: WovenMatterReleaseUpdateError.invalidManifest) { try invalid.validated() }
    let root = FileManager.default.temporaryDirectory.appending(
      path: "wovenmatter-release-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = WovenMatterReleaseUpdateInstaller(
      rootDirectory: root,
      downloadFile: { _, destination, _ in
        try payload.write(to: destination)
        return payload.count
      }
    )

    let wrongChecksum = try JSONDecoder().decode(WovenMatterReleaseManifest.self, from: Data(validManifest.utf8))
    await #expect(throws: WovenMatterReleaseInstallationError.checksumMismatch) {
      try await installer.download(wrongChecksum)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let release = try await installer.download(available)

    #expect(release.manifest == verifiedManifest)
    #expect(release.fileURL.deletingLastPathComponent() == root)
    #expect(try Data(contentsOf: release.fileURL) == payload)
    #expect(try await installer.cachedRelease(for: verifiedManifest) == release)
  }

  private let validManifest = """
  {
    "schema_version": 1,
    "version": "0.1.0",
    "build": 1,
    "architecture": "arm64",
    "minimum_macos": "26.0",
    "download_url": "https://github.com/wovenmatter/wovenmatter/releases/download/v0.1.0/WovenMatter_0.1.0_arm64.dmg",
    "release_url": "https://github.com/wovenmatter/wovenmatter/releases/tag/v0.1.0",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
  """
}
