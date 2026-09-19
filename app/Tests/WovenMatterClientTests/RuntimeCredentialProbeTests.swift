import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite("Runtime credential probe policy")
struct RuntimeCredentialProbeTests {
  private static let kinds: [AgentRuntimeKind] = [.codex, .claudeCode, .cursor, .pi, .hermes, .grokBuild, .openclaw]

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

  @Test("an explicit runtime check cannot start other enabled providers", arguments: Self.kinds)
  func scopedExplicitCheck(kind: AgentRuntimeKind) async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
    let discovered = resolution(kind)
    let calls = RuntimeProbeCalls()
    for selected in Self.kinds {
      _ = await LocalACPRuntimeVerifier.refresh(
        definition: definition,
        resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"),
        credentialCheckRuntimeKinds: [selected],
        verification: { _, _, _ in
          await calls.record()
          return discovered
        }
      )
    }
    #expect(await calls.count == 1)
  }

  @Test("passive discovery retains the last credential failure without retrying")
  func preservesPreviousAccountCheck() async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: .cursor))
    let discovered = resolution(.cursor)
    let prior = LocalACPRuntimeResolution(
      availability: .init(runtimeKind: .cursor, displayName: "Cursor", state: .authenticationRequired,
                          detail: "Previous account check needs access", executablePath: "/fixture/cursor"),
      launchConfiguration: nil
    )
    let result = await LocalACPRuntimeVerifier.refresh(
      definition: definition, resolution: discovered,
      workingDirectory: URL(fileURLWithPath: "/fixture"), previousResolution: prior,
      verification: { _, _, _ in Issue.record("Must not retry a failed account check"); return discovered }
    )
    #expect(result.availability == prior.availability)
    #expect(result.launchConfiguration == nil)
  }

  @Test("changed or missing executables invalidate cached readiness")
  func invalidatesStaleInstallation() async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: .cursor))
    let prior = resolution(.cursor)
    let moved = resolution(.cursor, path: "/new-fixture/cursor")
    let missing = LocalACPRuntimeResolution(
      availability: .init(runtimeKind: .cursor, displayName: "Cursor", state: .cliMissing,
                          detail: "Not installed", executablePath: nil),
      launchConfiguration: nil
    )
    for discovered in [moved, missing] {
      let result = await LocalACPRuntimeVerifier.refresh(
        definition: definition, resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"), previousResolution: prior,
        verification: { _, _, _ in Issue.record("Must not probe during discovery"); return discovered }
      )
      #expect(result.availability == discovered.availability)
    }
  }

  @Test("a canceled explicit check does not start a provider")
  func cancellationDoesNotProbe() async throws {
    let definition = try #require(LocalACPRuntimeCatalog.definition(for: .cursor))
    let discovered = resolution(.cursor)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await LocalACPRuntimeVerifier.refresh(
        definition: definition, resolution: discovered,
        workingDirectory: URL(fileURLWithPath: "/fixture"), credentialCheckRuntimeKinds: [.cursor],
        verification: { _, _, _ in Issue.record("Canceled check must not start a provider"); return discovered }
      )
    }
    #expect(await task.value.availability == discovered.availability)
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

private actor RuntimeProbeCalls {
  var count = 0
  func record() { count += 1 }
}
