import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite("Runtime credential probe policy")
struct RuntimeCredentialProbeTests {
  private static let kinds: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild]

  @Test("discovery reuses the previous resolution until an explicit check selects the runtime", arguments: Self.kinds)
  func passiveDiscoveryReusesPreviousResolution(kind: AgentRuntimeKind) async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
    let discovered = resolution(kind)
    let result = await LocalACPRuntimeVerifier.refresh(
      definition: definition,
      resolution: discovered,
      workingDirectory: URL(fileURLWithPath: "/fixture")
    )
    #expect(result.availability == discovered.availability)
    #expect(result.launchConfiguration?.executableURL == discovered.launchConfiguration?.executableURL)
    let previous = LocalACPRuntimeResolution(
      availability: .init(runtimeKind: kind, displayName: kind.displayName, state: .authenticationRequired,
                          detail: "Sign in", executablePath: discovered.availability.executablePath),
      launchConfiguration: nil
    )
    let reused = await LocalACPRuntimeVerifier.refresh(
      definition: definition,
      resolution: discovered,
      workingDirectory: URL(fileURLWithPath: "/fixture"),
      previousResolution: previous
    )
    #expect(reused.availability == previous.availability)
    #expect(reused.launchConfiguration == nil)
    for selected in Self.kinds {
      let checked = await LocalACPRuntimeVerifier.refresh(
        definition: definition,
        resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"),
        credentialCheckRuntimeKinds: [selected],
        previousResolution: previous
      )
      #expect(checked.availability == (selected == kind ? discovered.availability : previous.availability))
    }
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
