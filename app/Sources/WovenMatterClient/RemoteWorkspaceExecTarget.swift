import Foundation
import WovenMatterCore

public enum RemoteWorkspaceKind: String, Codable, CaseIterable, Sendable {
    case host

    public var displayName: String { "Linux host" }
}

public enum RemoteWorkspaceAccessMode: String, Codable, CaseIterable, Sendable {
    case fullRoot
    case user

    public var displayName: String { self == .fullRoot ? "Full root access" : "Normal user permissions" }
}

extension RemoteWorkspaceConfiguration {
    public func fullRootPermission(for runtimeKind: AgentRuntimeKind) -> String? {
        guard accessMode == .fullRoot else { return nil }
        switch runtimeKind {
        case .codex: return "agent-full-access"
        case .claudeCode, .grokBuild: return "bypassPermissions"
        case .defaultAgent: return "full"
        case .opencode: return "allow"
        default: return nil
        }
    }
}

/// One validated host command over SSH (`wm-exec exec`), for validation and repair.
/// Host paths are obtained from inspection/health, never from the Mac's home or
/// from fixed paths. The SSH transport is selected by its caller.
public struct RemoteWorkspaceExecTarget: Sendable {
    public let configuration: RemoteWorkspaceConfiguration

    public init(configuration: RemoteWorkspaceConfiguration) {
        self.configuration = configuration
    }

    public var workspaceRoot: String {
        get throws {
            return try absolute(configuration.workspaceRoot ?? dataRoot + "/workspace")
        }
    }

    public var databasesDirectory: String {
        get throws {
            return try absolute(configuration.databasesDirectory ?? dataRoot + "/databases")
        }
    }

    public var attachmentsDirectory: String {
        get throws {
            return try absolute(configuration.attachmentsDirectory ?? workspaceRoot + "/.wovenmatter/attachments")
        }
    }

    public var dataRoot: String {
        get throws {
            guard let root = configuration.dataRoot else {
                throw RemoteWorkspaceClientError.invalidResponse("Reconnect the Linux host to discover its installation directory.")
            }
            return try absolute(root)
        }
    }

    /// `wm-exec exec`: one host command with the session environment, for
    /// validation and repair. Agents never launch through it.
    public func prefix(workingDirectory: String? = nil, interactive: Bool = false,
                       environment: [String: String] = [:]) throws -> [String] {
        guard configuration.workspaceID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,47}$/) != nil else {
            throw RemoteWorkspaceClientError.invalidWorkspaceID
        }
        if let workingDirectory { _ = try absolute(workingDirectory) }
        guard environment.keys.allSatisfy({ $0.wholeMatch(of: /^[A-Z_][A-Z0-9_]*$/) != nil }),
              environment.values.allSatisfy({ !$0.contains("\0") }) else {
            throw RemoteWorkspaceClientError.invalidResponse("The remote process environment is invalid.")
        }
        var result = [try dataRoot + "/current/bin/wm-exec"]
        if let workingDirectory { result += ["--cwd", workingDirectory] }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            result += ["--env", "\(key)=\(value)"]
        }
        return result + ["exec"]
    }

    public func command(_ arguments: [String], workingDirectory: String? = nil,
                        interactive: Bool = false, environment: [String: String] = [:]) throws -> [String] {
        guard !arguments.isEmpty, arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw RemoteWorkspaceClientError.invalidResponse("The remote command is invalid.")
        }
        return try prefix(workingDirectory: workingDirectory, interactive: interactive, environment: environment) + arguments
    }

    public func shellCommand(_ arguments: [String], workingDirectory: String? = nil,
                             interactive: Bool = false, environment: [String: String] = [:]) throws -> String {
        try command(arguments, workingDirectory: workingDirectory, interactive: interactive, environment: environment)
            .map(Self.quote).joined(separator: " ")
    }

    public static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func absolute(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n"), !value.contains("\r"),
              !value.split(separator: "/").contains(".."), value.utf8.count <= 8192 else {
            throw RemoteWorkspaceClientError.invalidResponse("The host returned an invalid absolute directory.")
        }
        return value
    }
}
