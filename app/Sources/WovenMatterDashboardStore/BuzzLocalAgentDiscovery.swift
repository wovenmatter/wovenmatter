import Foundation
import WovenMatterCore

public enum BuzzLocalAgentDiscoveryError: LocalizedError, Equatable, Sendable {
  case localWorkspaceRequired
  case workspaceDisabled
  case storeUnavailable
  case malformedStore

  public var errorDescription: String? {
    switch self {
    case .localWorkspaceRequired:
      "Local Buzz agent discovery requires a local Workspace Link."
    case .workspaceDisabled:
      "The linked Buzz workspace is disabled."
    case .storeUnavailable:
      "The selected Buzz agent catalog is unavailable."
    case .malformedStore:
      "The selected Buzz agent catalog could not be read."
    }
  }
}

/// Reads Buzz Desktop state only through a narrow allowlisted projection.
/// Unknown fields, including private keys, auth tags, environment variables,
/// and provider configuration, are never represented by the decoder or result.
public struct BuzzLocalAgentDiscovery: Sendable {
  public init() {}

  public func candidates(
    for link: BuzzWorkspaceLink
  ) throws -> [BuzzWorkspaceAgentCandidate] {
    guard link.isEnabled else {
      throw BuzzLocalAgentDiscoveryError.workspaceDisabled
    }
    let storeURL = link.localAgentStoreURL
    guard storeURL.isFileURL,
          let data = try? Data(contentsOf: storeURL, options: [.mappedIfSafe]) else {
      throw BuzzLocalAgentDiscoveryError.storeUnavailable
    }
    let records: [StoredRecord]
    do {
      records = try JSONDecoder().decode([StoredRecord].self, from: data)
    } catch {
      throw BuzzLocalAgentDiscoveryError.malformedStore
    }

    var definitions: [String: StoredRecord] = [:]
    for record in records where record.instanceID == nil {
      guard let slug = record.nonBlank(record.slug) else { continue }
      definitions[slug] = record
    }
    return records.compactMap { record -> BuzzWorkspaceAgentCandidate? in
      guard let agentID = record.instanceID,
            Self.isAgentPubkey(agentID),
            record.isActive != false,
            record.backend?.type != "provider",
            let handle = record.nonBlank(record.name) else {
        return nil
      }
      let definitionID = record.nonBlank(record.personaID)
      let definition: StoredRecord?
      if let definitionID {
        guard let linked = definitions[definitionID] else { return nil }
        definition = linked
      } else {
        definition = nil
      }
      guard let harness = record.effectiveHarness(definition: definition) else {
        return nil
      }
      guard let runtimeKind = Self.runtimeKind(for: harness) else {
        return nil
      }
      return BuzzWorkspaceAgentCandidate(
        workspaceLinkID: link.id,
        agentID: agentID,
        handle: handle,
        displayName: record.nonBlank(record.displayName)
          ?? definition?.nonBlank(definition?.displayName)
          ?? handle,
        definitionID: definitionID,
        harnessIdentifier: harness,
        runtimeKind: runtimeKind
      )
    }.sorted {
      let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
      return comparison == .orderedSame
        ? $0.agentID < $1.agentID
        : comparison == .orderedAscending
    }
  }

  private static func runtimeKind(for harness: String) -> AgentRuntimeKind? {
    let identity = harness
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    return switch URL(fileURLWithPath: identity).lastPathComponent {
    case "openclaw": .openclaw
    case "claude", "claude-code", "claude-agent-acp", "claude-code-acp":
      .claudeCode
    case "codex", "codex-acp": .codex
    case "grok": .grokBuild
    case "hermes": .hermes
    case "cursor", "cursor-agent", "cursor-cli": .cursor
    case "opencode", "open-code": .opencode
    case "pi", "pi-acp", "pi-coding-agent", "picodingagent": .pi
    default: nil
    }
  }

  private static func isAgentPubkey(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
  }
}

private struct StoredRecord: Decodable {
  struct Backend: Decodable {
    let type: String
  }

  let pubkey: String?
  let name: String?
  let personaID: String?
  let agentCommandOverride: String?
  let displayName: String?
  let slug: String?
  let runtime: String?
  let isActive: Bool?
  let backend: Backend?

  var instanceID: String? { nonBlank(pubkey) }

  enum CodingKeys: String, CodingKey {
    case pubkey, name, slug, runtime, backend
    case personaID = "persona_id"
    case agentCommandOverride = "agent_command_override"
    case displayName = "display_name"
    case isActive = "is_active"
  }

  func nonBlank(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  func effectiveHarness(definition: StoredRecord?) -> String? {
    nonBlank(agentCommandOverride)
      ?? nonBlank(runtime)
      ?? definition?.nonBlank(definition?.runtime)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
