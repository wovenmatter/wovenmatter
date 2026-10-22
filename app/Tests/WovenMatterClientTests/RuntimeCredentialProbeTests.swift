import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite("Runtime credential probe policy")
struct RuntimeCredentialProbeTests {
  private static let kinds: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild]

  @Test("passive discovery preserves chat launch without starting provider sessions", arguments: Self.kinds)
  func passiveDiscovery(kind: AgentRuntimeKind) async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
    let discovered = resolution(kind)
    let result = await LocalACPRuntimeVerifier.refresh(
      definition: definition,
      resolution: discovered,
      workingDirectory: URL(fileURLWithPath: "/fixture"),
      verification: { _, _, _ in
        Issue.record("Passive startup, reopen and Settings discovery must not verify credentials")
        return discovered
      }
    )
    #expect(result.availability == discovered.availability)
    #expect(result.launchConfiguration?.executableURL == discovered.launchConfiguration?.executableURL)
  }

  private func resolution(_ kind: AgentRuntimeKind, path: String? = nil) -> LocalACPRuntimeResolution {
    let path = path ?? "/fixture/\(kind.rawValue)"
    return LocalACPRuntimeResolution(
      availability: .init(runtimeKind: kind, displayName: kind.displayName, state: .ready,
                          detail: "Installed", executablePath: path),
      launchConfiguration: .init(runtimeKind: kind, executableURL: URL(fileURLWithPath: path), arguments: [])
    )
  }
}
