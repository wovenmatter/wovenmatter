import Darwin
import Foundation
import WovenMatterCore
import WovenMatterClient

extension WovenMatterToolResponse: WovenSocketResponse {
    static func socketError(_ error: any Error) -> Self {
        Self(success: false, error: error.localizedDescription)
    }
}

typealias WovenMatterToolService = WovenSocketService<WovenMatterToolRequest, WovenMatterToolResponse>

enum WovenMatterCommandLine {
    static func run(arguments: [String], environment: [String: String]) -> Int32 {
        do {
            let command = try WovenMatterToolCommand(arguments)
            if command.wantsHelp {
                let help = command.group.map(WovenMatterToolCommand.help) ?? WovenMatterToolCommand.usage
                FileHandle.standardOutput.write(Data(help.utf8))
                return EXIT_SUCCESS
            }
            var args = arguments
            // File paths belong to the CLI host. Never ask the app to open an
            // arbitrary caller-supplied path on the Mac (remote callers included).
            if let index = args.firstIndex(of: "--file") {
                guard command.group == .notes, ["apply", "set-html"].contains(command.action), index + 1 < args.count else {
                    throw WorkspaceToolError.invalid("--file is supported by notes apply and notes set-html.")
                }
                let url = URL(fileURLWithPath: args[index + 1])
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 3 * 1_024 * 1_024 else { throw WovenNoteSocketError.requestTooLarge }
                let data = try Data(contentsOf: url)
                guard data.count <= 3 * 1_024 * 1_024, let value = String(data: data, encoding: .utf8) else {
                    throw WorkspaceToolError.invalid("The input file must be UTF-8 and at most 3 MiB.")
                }
                args.replaceSubrange(index...index + 1, with: [command.action == "set-html" ? "--html" : "--json", value])
            }
            if command.group == .notes, !args.contains("--note-id"), let noteID = environment["WOVENMATTER_NOTE_ID"],
               !["list", "create", "versions", "version", "restore"].contains(command.action) {
                args += ["--note-id", noteID]
            }
            let requestID = command.options["request-id"] ?? UUID().uuidString.lowercased()
            guard UUID(uuidString: requestID) != nil else { throw WorkspaceToolError.invalid("--request-id must be a UUID.") }
            guard let socketPath = environment["WOVENMATTER_SOCKET"], !socketPath.isEmpty else {
                throw WorkspaceToolError.invalid("WOVENMATTER_SOCKET is missing. Use the invocation supplied by this Woven Matter session.")
            }
            let request = WovenMatterToolRequest(arguments: args, requestID: requestID)
            let data = try forward(try JSONEncoder().encode(request), to: socketPath)
            let response = try JSONDecoder().decode(WovenMatterToolResponse.self, from: data)
            if !response.silent {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return response.success ? EXIT_SUCCESS : EXIT_FAILURE
        } catch {
            FileHandle.standardError.write(Data("wovenmatter: \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
    }

    static func forward(_ data: Data, to path: String) throws -> Data {
        guard data.count <= 4 * 1_024 * 1_024 else { throw WovenNoteSocketError.requestTooLarge }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WovenNoteSocketError.system(errno) }
        defer { Darwin.close(descriptor) }
        try configureSocket(descriptor)
        var address = try unixAddress(path: path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw WovenNoteSocketError.system(errno) }
        try writeMessage(data, to: descriptor, timeout: 30)
        _ = Darwin.shutdown(descriptor, SHUT_WR)
        return try readMessage(from: descriptor, timeout: 60, maximumBytes: 32 * 1_024 * 1_024)
    }
}
