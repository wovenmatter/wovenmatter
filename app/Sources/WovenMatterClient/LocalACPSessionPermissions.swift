import WovenMatterCore

/// Grok's permission policy is a process setting. Its ACP `session/set_mode`
/// currently acknowledges even unknown modes without applying a change.
enum LocalACPSessionPermissions {
    static func prepareLaunch(_ launch: LocalACPRuntimeLaunchConfiguration) throws -> (arguments: [String], explicitPermission: String?) {
        if let wrapped = launch.wrappedCommand {
            guard launch.arguments.indices.contains(wrapped.argumentIndex),
                  wrapped.harnessArgumentsStartIndex > 0,
                  wrapped.harnessArgumentsStartIndex <= wrapped.command.count else {
                throw LocalACPClientError.invalidLaunchConfiguration
            }
            let harnessArguments = try launchArguments(
                Array(wrapped.command.dropFirst(wrapped.harnessArgumentsStartIndex)),
                runtimeKind: launch.runtimeKind, permission: launch.requestedPermission
            )
            let command = Array(wrapped.command.prefix(wrapped.harnessArgumentsStartIndex)) + harnessArguments
            var arguments = launch.arguments
            arguments[wrapped.argumentIndex] = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            return (arguments, launch.requestedPermission ?? (launch.runtimeKind == .grokBuild ? explicitGrokPermission(in: harnessArguments) : nil))
        }
        let arguments = try launchArguments(launch.arguments, runtimeKind: launch.runtimeKind, permission: launch.requestedPermission)
        return (arguments, launch.requestedPermission ?? (launch.runtimeKind == .grokBuild ? explicitGrokPermission(in: arguments) : nil))
    }

    // `auto` is the existing persisted wire value for one-time approvals. Keep
    // its authority unchanged; it is Full access, not Cursor's smart Auto-review.
    static let cursorOptions = ["normal", "auto"]
    static let cursorMetadata: [String: SessionOptionMetadata] = [
        "normal": .init(name: "Ask for approval", description: "Show the approval requests Cursor sends. Native allow and deny rules still apply."),
        "auto": .init(name: "Full access", description: "Allow commands and edits without ordinary approval prompts in this conversation. Native deny rules still apply."),
    ]
    static let grokOptions = ["default", "acceptEdits", "auto", "bypassPermissions"]
    private static let supportedGrokOptions = grokOptions + ["dontAsk"]

    static let grokMetadata: [String: SessionOptionMetadata] = [
        "default": .init(name: "Ask for approval", description: "Grok asks for approval beyond its built-in read-only and preapproved actions."),
        "acceptEdits": .init(name: "Auto-accept edits", description: "Allow file edits; ask before other actions that need approval."),
        "auto": .init(name: "Auto", description: "Grok's safety checker decides which actions may run automatically."),
        "dontAsk": .init(name: "Don't ask", description: "Grok denies actions that are not already approved instead of asking."),
        "bypassPermissions": .init(name: "Full access", description: "Allow commands and edits without ordinary approval prompts. Native deny rules, hooks, and administrator policies still apply."),
    ]

    /// Keep a saved native deny-without-asking policy selectable while it is
    /// active, without offering it as a new approval preset.
    static func grokOptions(currentPermission: String?) -> [String] {
        currentPermission == "dontAsk" ? grokOptions + ["dontAsk"] : grokOptions
    }

    static func nativeOptions(runtimeKind: AgentRuntimeKind, options: [String]) -> [String] {
        guard runtimeKind == .claudeCode else { return options }
        // Keep any active legacy value and metadata readable, but don't offer
        // planning or deny-without-asking as an approval preset for new choices.
        return options.filter { $0 != "plan" && $0 != "dontAsk" }
    }

    /// Normalize known native policies without changing their identifiers or
    /// mistaking older Codex workspace presets for classifier-based review.
    static func nativeMetadata(
        runtimeKind: AgentRuntimeKind, options: [ACPJSONValue], idKeys: [String]
    ) -> [String: SessionOptionMetadata] {
        var result: [String: SessionOptionMetadata] = [:]
        for option in options {
            guard let id = idKeys.compactMap({ option[$0]?.stringValue }).first else {
                result.merge(nativeMetadata(runtimeKind: runtimeKind,
                    options: option["options"]?.arrayValue ?? [], idKeys: idKeys)) { _, latest in latest }
                continue
            }
            var name = option["name"]?.stringValue
            var description = option["description"]?.stringValue
            switch (runtimeKind, id) {
            case (.codex, "read-only"), (.claudeCode, "default"):
                name = "Ask for approval"
            case (.codex, "agent"):
                if option["_meta"]?["kind"]?.stringValue == "auto_review" {
                    name = "Approve for me"
                    description = "Only ask for actions detected as potentially unsafe."
                } else {
                    name = "Workspace access"
                    description = "Use Codex's workspace access preset with its native approval and sandbox rules."
                }
            case (.codex, "agent-full-access"), (.claudeCode, "bypassPermissions"):
                name = "Full access"
            case (.claudeCode, "auto"):
                name = "Auto"
                description = "Claude's model classifier decides which actions may run automatically."
            case (.claudeCode, "acceptEdits"):
                name = "Auto-accept edits"
            default:
                break
            }
            result[id] = SessionOptionMetadata(name: name, description: description)
        }
        return result
    }

    static func explicitGrokPermission(in arguments: [String]) -> String? {
        if arguments.contains("--always-approve") { return "bypassPermissions" }
        var permission: String?
        for (index, argument) in arguments.enumerated() {
            if argument == "--permission-mode", arguments.indices.contains(index + 1) {
                permission = arguments[index + 1]
            } else if argument.hasPrefix("--permission-mode=") {
                permission = String(argument.dropFirst("--permission-mode=".count))
            }
        }
        return permission.flatMap { supportedGrokOptions.contains($0) ? $0 : nil }
    }

    static func launchArguments(
        _ arguments: [String], runtimeKind: AgentRuntimeKind, permission: String?
    ) throws -> [String] {
        if runtimeKind == .cursor, let permission, !cursorOptions.contains(permission) {
            throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        guard runtimeKind == .grokBuild, let permission else { return arguments }
        guard supportedGrokOptions.contains(permission) else {
            throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        // Isolate the process policy from Grok's optional shared leader, and
        // replace conflicting explicit flags when reconnecting the same session.
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--permission-mode" {
                index += 2
                continue
            }
            if argument.hasPrefix("--permission-mode=")
                || ["--always-approve", "--leader", "--no-leader"].contains(argument) {
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        if let agentIndex = result.firstIndex(of: "agent") {
            result.insert("--no-leader", at: agentIndex + 1)
        }
        return ["--permission-mode", permission] + result
    }
}
