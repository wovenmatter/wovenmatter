import Foundation

/// Commands the native Hermes catalog makes available to desktop clients.
public enum HermesSlashCommands {
    public static func catalog(_ catalog: HermesValue) -> [LocalACPSlashCommand] {
        let tuiOnly = Set(catalog["categories"].array.filter { $0["name"].text == "TUI" }
            .flatMap { $0["pairs"].array.compactMap { $0.array.first?.string } })
        // These are implemented by Hermes Desktop itself, not by the native slash
        // worker. In particular, /new and /branch must not replace a worker's
        // identity while Woven Matter still owns the original conversation link.
        let clientActions: Set<String> = ["new", "reset", "branch", "fork", "resume", "sessions", "switch",
            "prompt", "compose", "profile", "skin", "wake", "journey", "browser", "title", "handoff", "yolo"]
        var seen: Set<String> = []
        return catalog["pairs"].array.compactMap { pair in
            let values = pair.array
            guard let raw = values.first?.string, raw.hasPrefix("/"),
                  !tuiOnly.contains(raw), catalog["commands"][raw]["desktop"].isNull,
                  let name = name(in: raw), !clientActions.contains(name), seen.insert(name).inserted else { return nil }
            return LocalACPSlashCommand(name: name, detail: values.dropFirst().first?.string)
        }
    }

    static func name(in text: String) -> String? {
        guard text.hasPrefix("/"), let first = text.dropFirst().first, !first.isWhitespace, let token = text.dropFirst().split(whereSeparator: \.isWhitespace).first,
              !token.isEmpty else { return nil }
        return String(token)
    }
}
