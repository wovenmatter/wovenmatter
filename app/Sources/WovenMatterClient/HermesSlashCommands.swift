import Foundation

/// Commands the native Hermes catalog makes available to desktop clients.
public enum HermesSlashCommands {
    // These are implemented by Hermes Desktop itself, not by the native slash
    // worker. In particular, /new and /branch must not replace a worker's
    // identity while Woven Matter still owns the original conversation link.
    private static let clientActions: Set<String> = ["new", "reset", "branch", "fork", "resume", "sessions", "switch",
        "prompt", "compose", "profile", "skin", "wake", "journey", "browser", "title", "handoff", "yolo"]

    public static func catalog(_ catalog: HermesValue) -> [LocalACPSlashCommand] {
        let tuiOnly = Set(catalog["categories"].array.filter { $0["name"].text == "TUI" }
            .flatMap { $0["pairs"].array.compactMap { $0.array.first?.string } })
        var seen: Set<String> = []
        return catalog["pairs"].array.compactMap { pair in
            let values = pair.array
            guard let raw = values.first?.string, raw.hasPrefix("/"),
                  !tuiOnly.contains(raw), catalog["commands"][raw]["desktop"].isNull,
                  let name = name(in: raw), !clientActions.contains(name), seen.insert(name).inserted else { return nil }
            return LocalACPSlashCommand(name: name, detail: values.dropFirst().first?.string)
        }
    }

    static func dispatch(_ text: String, sessionID: String, depth: Int = 0,
                         request: @Sendable (String, HermesValue) async throws -> HermesValue) async throws -> HermesValue {
        guard depth < 8, let name = HermesSlashCommands.name(in: text) else {
            throw HermesGatewayError.message("Hermes returned an invalid or circular command alias.")
        }
        guard !clientActions.contains(name) else {
            throw HermesGatewayError.message("This Hermes command requires its own desktop interface.")
        }
        let argument = String(text.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let result: HermesValue
        do {
            result = try await request("command.dispatch", ["session_id": .string(sessionID),
                "name": .string(name), "arg": .string(argument)])
        } catch HermesGatewayError.rpc(let code, let message)
            where code == 4018 && message == "not a quick/plugin/bundle/skill command: " + name {
            // Only this explicit no-handler response permits fallback. Other errors can
            // follow side effects, so retrying them through slash.exec could execute twice.
            result = try await request("slash.exec", ["session_id": .string(sessionID), "command": .string(text)])
        }
        if result["type"].text == "alias" {
            let target = result["target"].text
            guard !target.isEmpty else { throw HermesGatewayError.message("Hermes returned an empty command alias.") }
            let command = (target.hasPrefix("/") ? target : "/" + target)
                + (argument.isEmpty ? "" : " " + argument)
            return try await dispatch(command, sessionID: sessionID, depth: depth + 1, request: request)
        }
        return result
    }

    static func name(in text: String) -> String? {
        guard text.hasPrefix("/"), let first = text.dropFirst().first, !first.isWhitespace, let token = text.dropFirst().split(whereSeparator: \.isWhitespace).first,
              !token.isEmpty else { return nil }
        return String(token)
    }
}
