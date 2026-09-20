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

    static let cursorOptions = ["normal", "auto"]
    static let cursorMetadata: [String: SessionOptionMetadata] = [
        "normal": .init(name: "Native approvals", description: "Show the approval requests Cursor sends. Native allow and deny rules still apply."),
        "auto": .init(name: "Auto-approve requests", description: "Approve each request Cursor sends once for this conversation. Native allow and deny rules still apply."),
    ]
    static let grokOptions = ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions"]

    static let grokMetadata: [String: SessionOptionMetadata] = [
        "default": .init(name: "Ask", description: "Grok asks for approval beyond its built-in read-only and preapproved actions."),
        "acceptEdits": .init(name: "Accept edits", description: "Grok permits file edits and asks before other actions that need approval."),
        "auto": .init(name: "Auto", description: "Grok's safety checker decides which actions may run automatically."),
        "dontAsk": .init(name: "Don't ask", description: "Grok denies actions that are not already approved instead of asking."),
        "bypassPermissions": .init(name: "Always approve", description: "Grok bypasses ordinary approvals. Native deny rules, hooks, and administrator policies still apply."),
    ]

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
        return permission.flatMap { grokOptions.contains($0) ? $0 : nil }
    }

    static func launchArguments(
        _ arguments: [String], runtimeKind: AgentRuntimeKind, permission: String?
    ) throws -> [String] {
        if runtimeKind == .cursor, let permission, !cursorOptions.contains(permission) {
            throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        guard runtimeKind == .grokBuild, let permission else { return arguments }
        guard grokOptions.contains(permission) else {
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
