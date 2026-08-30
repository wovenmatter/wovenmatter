import Foundation
import Testing
@testable import WovenMatterClient

@Suite("Release updates")
struct ReleaseUpdateTests {
  @Test("compares semantic release versions")
  func versionComparison() throws {
    let current = try #require(WovenMatterReleaseVersion("0.1.0"))
    let patch = try #require(WovenMatterReleaseVersion("0.1.1"))
    let minor = try #require(WovenMatterReleaseVersion("0.2.0"))
    #expect(current < patch)
    #expect(patch < minor)
    #expect(WovenMatterReleaseVersion("0.1") == nil)
    #expect(WovenMatterReleaseVersion("v0.1.0") == nil)
  }

  @Test("accepts only the official arm64 release path")
  func validatesManifest() throws {
    let manifest = try JSONDecoder().decode(
      WovenMatterReleaseManifest.self,
      from: Data(validManifest.utf8)
    )
    #expect(try manifest.validated() == manifest)

    let changed = validManifest.replacingOccurrences(
      of: "WovenMatter_0.1.0_arm64.dmg",
      with: "WovenMatter_0.1.0_x64.dmg"
    )
    let invalid = try JSONDecoder().decode(
      WovenMatterReleaseManifest.self,
      from: Data(changed.utf8)
    )
    #expect(throws: WovenMatterReleaseUpdateError.invalidManifest) {
      try invalid.validated()
    }
  }

  @Test("reports a newer published version")
  func updateAvailable() async throws {
    let client = WovenMatterReleaseUpdateClient { url in
      let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      ))
      return (Data(validManifest.utf8), response)
    }
    let result = try await client.check(currentVersion: "0.0.9")
    guard case .available(let manifest) = result else {
      Issue.record("Expected an available release")
      return
    }
    #expect(manifest.version == "0.1.0")
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
