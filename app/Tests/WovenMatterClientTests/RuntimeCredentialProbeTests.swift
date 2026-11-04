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


  @Test("repairing an installation at the same path clears discovery failures without credential checks", arguments: Self.kinds)
  func repairedInstallationClearsPriorFailure(kind: AgentRuntimeKind) async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
    let discovered = resolution(kind)
    for state in [LocalACPRuntimeAvailability.State.adapterOutdated, .adapterMissing, .cliMissing] {
      let previous = LocalACPRuntimeResolution(availability: .init(runtimeKind: kind, displayName: kind.displayName,
        state: state, detail: "Previous installation failure", executablePath: discovered.availability.executablePath), launchConfiguration: nil)
      let refreshed = await LocalACPRuntimeVerifier.refresh(definition: definition, resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"), previousResolution: previous,
        verification: { _, _, _ in Issue.record("Repair discovery must not start a provider"); return discovered })
      #expect(refreshed.availability == discovered.availability)
      #expect(refreshed.launchConfiguration?.executableURL == discovered.launchConfiguration?.executableURL)
    }
  }

  @Test("passive discovery retains same-path readiness failures until explicit verification", arguments: Self.kinds)
  func explicitReadinessFailuresRemainScoped(kind: AgentRuntimeKind) async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
    let discovered = resolution(kind)
    for state in [LocalACPRuntimeAvailability.State.authenticationRequired, .executableUnavailable] {
      let previous = LocalACPRuntimeResolution(availability: .init(runtimeKind: kind, displayName: kind.displayName,
        state: state, detail: "Explicit readiness failure", executablePath: discovered.availability.executablePath), launchConfiguration: nil)
      let retained = await LocalACPRuntimeVerifier.refresh(definition: definition, resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"), previousResolution: previous,
        verification: { _, _, _ in Issue.record("Passive discovery must not recheck readiness"); return discovered })
      #expect(retained.availability == previous.availability)
      #expect(retained.launchConfiguration == nil)
      let rechecked = await LocalACPRuntimeVerifier.refresh(definition: definition, resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"), credentialCheckRuntimeKinds: [kind], previousResolution: previous,
        verification: { _, _, _ in discovered })
      #expect(rechecked.availability == discovered.availability)
      #expect(rechecked.launchConfiguration != nil)
      let moved = resolution(kind, path: "/fixture/replaced/\(kind.rawValue)")
      let changed = await LocalACPRuntimeVerifier.refresh(definition: definition, resolution: moved,
        workingDirectory: URL(fileURLWithPath: "/fixture"), previousResolution: previous,
        verification: { _, _, _ in Issue.record("Path discovery must not recheck readiness"); return moved })
      #expect(changed.availability == moved.availability)
      #expect(changed.launchConfiguration != nil)
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
