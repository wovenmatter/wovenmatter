import Foundation
import WovenMatterClient
import WovenMatterCore

public enum BuzzLocalAgentLaunchError: LocalizedError, Equatable, Sendable {
  case localWorkspaceRequired
  case workspaceDisabled
  case workspaceUnavailable
  case storeUnavailable
  case malformedStore
  case malformedGlobalConfiguration
  case agentUnavailable
  case providerAgentUnsupported
  case orphanedDefinition
  case harnessUnsupported(String)
  case harnessUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .localWorkspaceRequired:
      "Local Buzz agent launch requires a local Workspace Link."
    case .workspaceDisabled:
      "The linked Buzz workspace is disabled."
    case .workspaceUnavailable:
      "The linked Buzz workspace is unavailable."
    case .storeUnavailable:
      "The selected Buzz agent catalog is unavailable."
    case .malformedStore:
      "The selected Buzz agent catalog could not be read."
    case .malformedGlobalConfiguration:
      "The Buzz agent defaults could not be read."
    case .agentUnavailable:
      "The selected Buzz agent is no longer available in this workspace."
    case .providerAgentUnsupported:
      "This agent is hosted by a provider and cannot be launched from the local workspace."
    case .orphanedDefinition:
      "This agent’s linked definition is missing."
    case .harnessUnsupported(let harness):
      "The linked Buzz agent uses unsupported harness \(harness)."
    case .harnessUnavailable(let harness):
      "The linked Buzz agent harness \(harness) is not installed."
    }
  }
}

/// Transient launch material for one local Woven session. It may carry
/// provider credentials in `launch.environment`; callers must never persist or
/// log it. Buzz identity and Buzz control fields are stripped.
public struct BuzzLocalAgentLaunch: Sendable {
  public let launch: LocalACPRuntimeLaunchConfiguration
  public let workingDirectory: URL
  public let systemPrompt: String?
  public let model: String?
  public let provider: String?
  public let authoritativeStateRoot: String?

  public init(
    launch: LocalACPRuntimeLaunchConfiguration,
    workingDirectory: URL,
    systemPrompt: String?,
    model: String?,
    provider: String?,
    authoritativeStateRoot: String? = nil
  ) {
    self.launch = launch
    self.workingDirectory = workingDirectory
    self.systemPrompt = systemPrompt
    self.model = model
    self.provider = provider
    self.authoritativeStateRoot = authoritativeStateRoot
  }
}

public struct BuzzLocalAgentLaunchResolver: Sendable {
  private enum Mode {
    case acp
    case directGateway(port: Int)
    var isDirectGateway: Bool {
      if case .directGateway = self { return true }
      return false
    }
  }
  typealias ExecutableResolver = @Sendable (String) -> URL?
  private let resolveExecutable: ExecutableResolver
  private let executableSearchPath: @Sendable () -> String

  public init() {
    resolveExecutable = LocalACPRuntimeResolver.resolveExecutable(named:)
    executableSearchPath = { LocalACPRuntimeResolver.executableSearchPath }
  }

  init(
    resolveExecutable: @escaping ExecutableResolver,
    executableSearchPath: @escaping @Sendable () -> String = { "/usr/bin:/bin" }
  ) {
    self.resolveExecutable = resolveExecutable
    self.executableSearchPath = executableSearchPath
  }

  public func resolve(
    agentID: String,
    in link: BuzzWorkspaceLink
  ) throws -> BuzzLocalAgentLaunch {
    try resolve(agentID: agentID, in: link, mode: .acp)
  }

  public func resolveDirectGateway(
    agentID: String,
    in link: BuzzWorkspaceLink,
    port: Int
  ) throws -> BuzzLocalAgentLaunch {
    try resolve(agentID: agentID, in: link, mode: .directGateway(port: port))
  }

  private func resolve(
    agentID: String,
    in link: BuzzWorkspaceLink,
    mode: Mode
  ) throws -> BuzzLocalAgentLaunch {
    guard link.isEnabled else {
      throw BuzzLocalAgentLaunchError.workspaceDisabled
    }
    let workingDirectory = link.localWorkspaceURL
    guard workingDirectory.isFileURL,
          FileManager.default.fileExists(atPath: workingDirectory.path) else {
      throw BuzzLocalAgentLaunchError.workspaceUnavailable
    }
    let storeURL = link.localAgentStoreURL
    guard storeURL.isFileURL,
          let data = try? Data(contentsOf: storeURL, options: [.mappedIfSafe]) else {
      throw BuzzLocalAgentLaunchError.storeUnavailable
    }
    let records: [LaunchRecord]
    do {
      records = try JSONDecoder().decode([LaunchRecord].self, from: data)
    } catch {
      throw BuzzLocalAgentLaunchError.malformedStore
    }

    guard let record = records.first(where: {
      $0.nonBlank($0.pubkey) == agentID
    }), record.isActive != false else {
      throw BuzzLocalAgentLaunchError.agentUnavailable
    }
    guard record.backend?.type != "provider" else {
      throw BuzzLocalAgentLaunchError.providerAgentUnsupported
    }

    var definitions: [String: LaunchRecord] = [:]
    for definition in records where definition.nonBlank(definition.pubkey) == nil {
      guard let slug = definition.nonBlank(definition.slug) else { continue }
      definitions[slug] = definition
    }
    let definition: LaunchRecord?
    if let definitionID = record.nonBlank(record.personaID) {
      guard let linked = definitions[definitionID] else {
        throw BuzzLocalAgentLaunchError.orphanedDefinition
      }
      definition = linked
    } else {
      definition = nil
    }

    let harnessIdentity = record.nonBlank(record.agentCommandOverride)
      ?? record.nonBlank(record.runtime)
      ?? definition?.nonBlank(definition?.runtime)
    guard let harnessIdentity else {
      throw BuzzLocalAgentLaunchError.harnessUnsupported("unknown")
    }
    let harness = try Self.harness(for: harnessIdentity)
    guard let executable = resolveExecutable(harness.command) else {
      throw BuzzLocalAgentLaunchError.harnessUnavailable(harness.command)
    }

    let global = try globalConfiguration(beside: storeURL)
    let arguments: [String]
    switch mode {
    case .acp:
      arguments = Self.normalizedArguments(record.agentArgs ?? [], defaultArguments: harness.defaultArguments)
    case .directGateway(let port):
      guard harness.runtimeKind == .openclaw else {
        throw BuzzLocalAgentLaunchError.harnessUnsupported(harnessIdentity)
      }
      arguments = [
        "gateway", "--port", String(port), "--bind", "loopback", "--auth", "none",
      ]
    }
    var environment = harness.defaultEnvironment
    environment["PATH"] = Self.searchPath(
      executable: executable,
      configured: executableSearchPath()
    )
    for layer in [
      global.environment,
      definition?.environment ?? [:],
      record.environment,
    ] {
      for (key, value) in layer where Self.allowedEnvironment(key: key, value: value, mode: mode) {
        environment[key] = value
      }
    }
    environment = environment.filter {
      Self.allowedEnvironment(key: $0.key, value: $0.value, mode: mode)
    }

    if harness.runtimeKind == .claudeCode,
       let claude = resolveExecutable("claude") {
      environment["CLAUDE_CODE_EXECUTABLE"] = claude.path
    }

    return BuzzLocalAgentLaunch(
      launch: LocalACPRuntimeLaunchConfiguration(
        runtimeKind: harness.runtimeKind,
        executableURL: executable,
        arguments: arguments,
        environment: environment,
        environmentKeysToRemove: Array(
          mode.isDirectGateway
            ? Self.forbiddenEnvironmentKeys
            : Self.forbiddenEnvironmentKeys.union(Self.openClawPathEnvironmentKeys)
        ).sorted(),
        environmentKeyPrefixesToRemove: ["BUZZ_", "NOSTR_"]
      ),
      workingDirectory: workingDirectory,
      systemPrompt: definition == nil
        ? record.nonBlank(record.systemPrompt)
        : definition?.nonBlank(definition?.systemPrompt),
      model: Self.effectiveValue(
        linked: definition,
        definitionValue: definition?.model,
        instanceValue: record.model,
        globalValue: global.model
      ),
      provider: Self.effectiveValue(
        linked: definition,
        definitionValue: definition?.provider,
        instanceValue: record.provider,
        globalValue: global.provider
      ),
      authoritativeStateRoot: Self.authoritativeStateRoot(environment: environment)
    )
  }

  private func globalConfiguration(
    beside storeURL: URL
  ) throws -> GlobalLaunchConfiguration {
    let url = storeURL.deletingLastPathComponent()
      .appending(path: "global-agent-config.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      return GlobalLaunchConfiguration()
    }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          let configuration = try? JSONDecoder().decode(
            GlobalLaunchConfiguration.self,
            from: data
          ) else {
      throw BuzzLocalAgentLaunchError.malformedGlobalConfiguration
    }
    return configuration
  }

  private static func effectiveValue(
    linked definition: LaunchRecord?,
    definitionValue: String?,
    instanceValue: String?,
    globalValue: String?
  ) -> String? {
    if definition != nil {
      return nonBlank(definitionValue) ?? nonBlank(globalValue)
    }
    return nonBlank(instanceValue) ?? nonBlank(globalValue)
  }

  private static func harness(for rawValue: String) throws -> Harness {
    let identity = URL(fileURLWithPath: rawValue).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    switch identity {
    case "codex", "codex-acp":
      return Harness(
        runtimeKind: .codex,
        command: rawValue.contains("/") ? rawValue : "codex-acp",
        defaultArguments: []
      )
    case "claude", "claude-code", "claude-agent-acp", "claude-code-acp":
      let command = rawValue.contains("/") || identity.hasSuffix("-acp")
        ? rawValue : "claude-agent-acp"
      return Harness(
        runtimeKind: .claudeCode,
        command: command,
        defaultArguments: []
      )
    case "grok":
      return Harness(
        runtimeKind: .grokBuild,
        command: rawValue.contains("/") ? rawValue : "grok",
        defaultArguments: ["agent", "--always-approve", "stdio"]
      )
    case "openclaw":
      return Harness(
        runtimeKind: .openclaw,
        command: rawValue.contains("/") ? rawValue : "openclaw",
        defaultArguments: ["acp"]
      )
    case "cursor", "cursor-agent", "cursor-cli":
      let command = rawValue.contains("/") || identity == "cursor-agent"
        ? rawValue : CursorACPSupport.commandName
      return Harness(
        runtimeKind: .cursor,
        command: command,
        defaultArguments: ["acp"]
      )
    case "opencode", "open-code":
      return Harness(
        runtimeKind: .opencode,
        command: rawValue.contains("/") ? rawValue : "opencode",
        defaultArguments: ["acp"]
      )
    case "pi", "pi-acp", "pi-coding-agent", "picodingagent":
      let command = rawValue.contains("/") || identity == "pi-acp"
        ? rawValue : "pi-acp"
      return Harness(
        runtimeKind: .pi,
        command: command,
        defaultArguments: []
      )
    case "buzz-acp", "buzz-agent":
      throw BuzzLocalAgentLaunchError.harnessUnsupported(identity)
    default:
      throw BuzzLocalAgentLaunchError.harnessUnsupported(identity)
    }
  }

  private static func allowedEnvironment(key: String, value: String, mode: Mode) -> Bool {
    guard !value.contains("\0"), value.utf8.count <= 32 * 1_024 else {
      return false
    }
    let bytes = Array(key.utf8)
    guard let first = bytes.first,
          first == 95 || (65...90).contains(first) || (97...122).contains(first),
          bytes.dropFirst().allSatisfy({
            $0 == 95 || (48...57).contains($0)
              || (65...90).contains($0) || (97...122).contains($0)
          }) else {
      return false
    }
    let upper = key.uppercased()
    if Self.openClawPathEnvironmentKeys.contains(upper) {
      if case .directGateway = mode { return true }
      return false
    }
    let relaySilent = !upper.hasPrefix("BUZZ_")
      && !upper.hasPrefix("NOSTR_")
      && !forbiddenEnvironmentKeys.contains(upper)
    guard relaySilent else { return false }
    if case .directGateway = mode {
      return !upper.contains("TOKEN") && !upper.contains("PASSWORD")
    }
    return true
  }

  /// OpenClaw host wiring is not uniformly prefixed by Buzz, so these exact
  /// keys cover the reserved Buzz environment surface. They
  /// must be removed from both stored launch layers and the inherited Mac app
  /// environment without suppressing unrelated future OpenClaw provider keys.
  private static let forbiddenEnvironmentKeys: Set<String> = [
    "OPENCLAW_GATEWAY_PASSWORD",
    "OPENCLAW_GATEWAY_PORT",
    "OPENCLAW_GATEWAY_TOKEN",
  ]
  private static let openClawPathEnvironmentKeys: Set<String> = [
    "OPENCLAW_CONFIG_PATH", "OPENCLAW_STATE_DIR", "OPENCLAW_WORKSPACE_DIR",
  ]

  private static func authoritativeStateRoot(environment: [String: String]) -> String? {
    environment["OPENCLAW_STATE_DIR"]
      ?? environment["OPENCLAW_CONFIG_PATH"]
      ?? environment["OPENCLAW_WORKSPACE_DIR"]
  }

  private static func searchPath(executable: URL, configured: String) -> String {
    ([executable.deletingLastPathComponent().path]
      + configured.split(separator: ":").map(String.init))
      .reduce(into: [String]()) { paths, value in
        if !value.isEmpty, !paths.contains(value) { paths.append(value) }
      }
      .joined(separator: ":")
  }

  private static func normalizedArguments(
    _ arguments: [String],
    defaultArguments: [String]
  ) -> [String] {
    let normalized = arguments.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !normalized.isEmpty else { return defaultArguments }
    if normalized.count == 1,
       normalized[0].caseInsensitiveCompare("acp") == .orderedSame,
       defaultArguments.isEmpty {
      return defaultArguments
    }
    return normalized
  }

  private static func nonBlank(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}


private struct Harness {
  let runtimeKind: AgentRuntimeKind
  let command: String
  let defaultArguments: [String]
  let defaultEnvironment: [String: String]

  init(
    runtimeKind: AgentRuntimeKind,
    command: String,
    defaultArguments: [String],
    defaultEnvironment: [String: String] = [:]
  ) {
    self.runtimeKind = runtimeKind
    self.command = command
    self.defaultArguments = defaultArguments
    self.defaultEnvironment = defaultEnvironment
  }
}

private struct LaunchRecord: Decodable {
  struct Backend: Decodable { let type: String }

  let pubkey: String?
  let name: String?
  let personaID: String?
  let agentCommandOverride: String?
  let agentArgs: [String]?
  let slug: String?
  let runtime: String?
  let isActive: Bool?
  let backend: Backend?
  let environment: [String: String]
  let systemPrompt: String?
  let model: String?
  let provider: String?

  enum CodingKeys: String, CodingKey {
    case pubkey, name, slug, runtime, backend, model, provider
    case personaID = "persona_id"
    case agentCommandOverride = "agent_command_override"
    case agentArgs = "agent_args"
    case isActive = "is_active"
    case environment = "env_vars"
    case systemPrompt = "system_prompt"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pubkey = try container.decodeIfPresent(String.self, forKey: .pubkey)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    personaID = try container.decodeIfPresent(String.self, forKey: .personaID)
    agentCommandOverride = try container.decodeIfPresent(
      String.self,
      forKey: .agentCommandOverride
    )
    agentArgs = try container.decodeIfPresent([String].self, forKey: .agentArgs)
    slug = try container.decodeIfPresent(String.self, forKey: .slug)
    runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
    isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
    backend = try container.decodeIfPresent(Backend.self, forKey: .backend)
    environment = try container.decodeIfPresent(
      [String: String].self,
      forKey: .environment
    ) ?? [:]
    systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
  }

  func nonBlank(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}

private struct GlobalLaunchConfiguration: Decodable {
  let environment: [String: String]
  let provider: String?
  let model: String?

  init(
    environment: [String: String] = [:],
    provider: String? = nil,
    model: String? = nil
  ) {
    self.environment = environment
    self.provider = provider
    self.model = model
  }

  enum CodingKeys: String, CodingKey {
    case environment = "env_vars"
    case provider, model
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    environment = try container.decodeIfPresent(
      [String: String].self,
      forKey: .environment
    ) ?? [:]
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    model = try container.decodeIfPresent(String.self, forKey: .model)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
