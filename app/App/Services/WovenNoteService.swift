import Darwin
import Foundation
import WovenMatterCore

final class WovenNoteService: @unchecked Sendable {
    typealias Handler = @Sendable (NoteEditingRequest) async -> NoteEditingResponse

    let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.wovenmatter.note-service")
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?

    init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() throws {
        try stop()
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WovenNoteSocketError.system(errno) }
        do {
            var address = try unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, Darwin.listen(descriptor, 8) == 0 else {
                throw WovenNoteSocketError.system(errno)
            }
            guard Darwin.chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw WovenNoteSocketError.system(errno)
            }
            socket = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnection() }
            source.setCancelHandler { Darwin.close(descriptor) }
            self.source = source
            source.resume()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func stop() throws {
        source?.cancel()
        source = nil
        socket = -1
        if FileManager.default.fileExists(atPath: socketURL.path) {
            try FileManager.default.removeItem(at: socketURL)
        }
    }

    deinit { try? stop() }

    private func acceptConnection() {
        guard socket >= 0 else { return }
        let client = Darwin.accept(socket, nil, nil)
        guard client >= 0 else { return }
        let handler = handler
        Task.detached {
            defer { Darwin.close(client) }
            let response: NoteEditingResponse
            do {
                let request = try JSONDecoder().decode(
                    NoteEditingRequest.self,
                    from: readMessage(from: client)
                )
                response = await handler(request)
            } catch {
                response = NoteEditingResponse(
                    success: false,
                    noteID: "",
                    error: error.localizedDescription
                )
            }
            try? writeMessage(try JSONEncoder().encode(response), to: client)
        }
    }
}

enum WovenNoteCommandLine {
    static func run(arguments: [String], environment: [String: String]) -> Int32 {
        if arguments.first.map({ $0 == "help" || $0 == "--help" || $0 == "-h" }) == true {
            FileHandle.standardOutput.write(Data(usage.utf8))
            return EXIT_SUCCESS
        }
        do {
            let request = try request(arguments: arguments, environment: environment)
            let socketPath = try requiredEnvironment("WOVEN_NOTE_SOCKET", environment)
            let response = try send(request, socketPath: socketPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return response.success ? EXIT_SUCCESS : EXIT_FAILURE
        } catch {
            FileHandle.standardError.write(Data("woven-note: \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
    }

    static let usage = """
    Usage: woven-note COMMAND [OPTIONS]

      read
      append --text TEXT [--style STYLE] [--revision REVISION]
      insert --text TEXT [--after BLOCK_ID] [--style STYLE] [--revision REVISION]
      replace-block --id BLOCK_ID --json BLOCK_JSON [--revision REVISION]
      delete-block --id BLOCK_ID [--revision REVISION]
      format --block-id BLOCK_ID --style STYLE [--revision REVISION]
      set-title --title TITLE [--revision REVISION]
      table create [--rows N] [--columns N] [--header] [--revision REVISION]
      table set-cell --table-id ID --row N --column N --text TEXT [--revision REVISION]
      table add-row|remove-row|add-column|remove-column ... [--revision REVISION]
      set-html --html HTML | --file PATH [--revision REVISION]
      link --source-id ID --database-id ID --path PATH [--query SQL] [--table-id ID] [--revision REVISION]
      unlink [--table-id ID] [--revision REVISION]
      apply --json OPERATIONS_JSON | --file PATH [--revision REVISION]

    Set WOVEN_NOTE_ID and WOVEN_NOTE_SOCKET, or pass --note-id explicitly.
    Paragraph styles: paragraph, heading1...heading6, bulletedList, numberedList.
    """ + "\n"

    static func request(
        arguments: [String],
        environment: [String: String]
    ) throws -> NoteEditingRequest {
        var parser = WovenNoteArguments(arguments)
        let command = try parser.next("command")
        let noteID = parser.value(for: "--note-id") ?? environment["WOVEN_NOTE_ID"]
        guard let noteID, !noteID.isEmpty else { throw WovenNoteCLIError.missingNoteID }
        let revision = parser.value(for: "--revision")

        switch command {
        case "read":
            return NoteEditingRequest(command: .read, noteID: noteID)
        case "append":
            return .applying(
                noteID: noteID,
                revision: revision,
                .appendText(
                    try parser.requiredValue(for: "--text"),
                    try parser.style()
                )
            )
        case "insert":
            return .applying(
                noteID: noteID,
                revision: revision,
                .insertText(
                    afterBlockID: parser.value(for: "--after"),
                    text: try parser.requiredValue(for: "--text"),
                    style: try parser.style()
                )
            )
        case "replace-block":
            let id = try parser.requiredValue(for: "--id")
            let block = try JSONDecoder().decode(
                NoteBlock.self,
                from: Data(try parser.requiredValue(for: "--json").utf8)
            )
            return .applying(noteID: noteID, revision: revision, .replaceBlock(id: id, block: block))
        case "delete-block":
            return .applying(
                noteID: noteID,
                revision: revision,
                .deleteBlock(id: try parser.requiredValue(for: "--id"))
            )
        case "format":
            return .applying(
                noteID: noteID,
                revision: revision,
                .setParagraphStyle(
                    blockID: try parser.requiredValue(for: "--block-id"),
                    style: try parser.style(required: true)
                )
            )
        case "set-title":
            return .applying(
                noteID: noteID,
                revision: revision,
                .setTitle(try parser.requiredValue(for: "--title"))
            )
        case "set-html":
            let html: String
            if let value = parser.value(for: "--html") {
                html = value
            } else {
                html = try String(
                    contentsOf: URL(fileURLWithPath: parser.requiredValue(for: "--file")),
                    encoding: .utf8
                )
            }
            return .applying(noteID: noteID, revision: revision, .setHTML(html))
        case "link":
            let link = DatabaseArtifactLink(
                sourceID: try parser.requiredValue(for: "--source-id"),
                databaseID: try parser.requiredValue(for: "--database-id"),
                relativePath: try parser.requiredValue(for: "--path"),
                sqliteQuery: parser.value(for: "--query")
            )
            let operation: NoteEditOperation = if let tableID = parser.value(for: "--table-id") {
                .setTableDatabaseLink(tableID: tableID, link: link)
            } else {
                .setArtifactDatabaseLink(link)
            }
            return .applying(noteID: noteID, revision: revision, operation)
        case "unlink":
            let operation: NoteEditOperation = if let tableID = parser.value(for: "--table-id") {
                .setTableDatabaseLink(tableID: tableID, link: nil)
            } else {
                .setArtifactDatabaseLink(nil)
            }
            return .applying(noteID: noteID, revision: revision, operation)
        case "table":
            return try tableRequest(noteID: noteID, revision: revision, parser: &parser)
        case "apply":
            let data: Data
            if let json = parser.value(for: "--json") {
                data = Data(json.utf8)
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: parser.requiredValue(for: "--file")))
            }
            return NoteEditingRequest(
                command: .apply,
                noteID: noteID,
                expectedRevision: revision,
                operations: try JSONDecoder().decode([NoteEditOperation].self, from: data)
            )
        default:
            throw WovenNoteCLIError.unknownCommand(command)
        }
    }

    private static func tableRequest(
        noteID: String,
        revision: String?,
        parser: inout WovenNoteArguments
    ) throws -> NoteEditingRequest {
        let action = try parser.next("table action")
        let operation: NoteEditOperation
        switch action {
        case "create":
            operation = .createTable(
                afterBlockID: parser.value(for: "--after"),
                rows: try parser.integer(for: "--rows", default: 3),
                columns: try parser.integer(for: "--columns", default: 3),
                headerRow: parser.contains("--header")
            )
        case "set-cell":
            operation = .setTableCell(
                tableID: try parser.requiredValue(for: "--table-id"),
                row: try parser.integer(for: "--row"),
                column: try parser.integer(for: "--column"),
                runs: [NoteTextRun(text: try parser.requiredValue(for: "--text"))]
            )
        case "add-row":
            operation = .addTableRow(
                tableID: try parser.requiredValue(for: "--table-id"),
                after: try parser.optionalInteger(for: "--after")
            )
        case "remove-row":
            operation = .removeTableRow(
                tableID: try parser.requiredValue(for: "--table-id"),
                row: try parser.integer(for: "--row")
            )
        case "add-column":
            operation = .addTableColumn(
                tableID: try parser.requiredValue(for: "--table-id"),
                after: try parser.optionalInteger(for: "--after")
            )
        case "remove-column":
            operation = .removeTableColumn(
                tableID: try parser.requiredValue(for: "--table-id"),
                column: try parser.integer(for: "--column")
            )
        default:
            throw WovenNoteCLIError.unknownCommand("table \(action)")
        }
        return .applying(noteID: noteID, revision: revision, operation)
    }

    private static func requiredEnvironment(
        _ key: String,
        _ environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw WovenNoteCLIError.missingEnvironment(key)
        }
        return value
    }

    static func send(
        _ request: NoteEditingRequest,
        socketPath: String
    ) throws -> NoteEditingResponse {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw WovenNoteSocketError.system(errno) }
        defer { Darwin.close(socket) }
        var address = try unixAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw WovenNoteSocketError.system(errno) }
        try writeMessage(try JSONEncoder().encode(request), to: socket)
        _ = Darwin.shutdown(socket, SHUT_WR)
        return try JSONDecoder().decode(NoteEditingResponse.self, from: readMessage(from: socket))
    }
}

private struct WovenNoteArguments {
    private var values: [String]

    init(_ values: [String]) { self.values = values }

    mutating func next(_ label: String) throws -> String {
        guard !values.isEmpty else { throw WovenNoteCLIError.missingArgument(label) }
        return values.removeFirst()
    }

    mutating func contains(_ flag: String) -> Bool {
        guard let index = values.firstIndex(of: flag) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func value(for flag: String) -> String? {
        guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
            return nil
        }
        values.remove(at: index)
        return values.remove(at: index)
    }

    mutating func requiredValue(for flag: String) throws -> String {
        guard let value = value(for: flag) else { throw WovenNoteCLIError.missingArgument(flag) }
        return value
    }

    mutating func integer(for flag: String, default defaultValue: Int? = nil) throws -> Int {
        if let raw = value(for: flag) {
            guard let value = Int(raw) else { throw WovenNoteCLIError.invalidInteger(flag) }
            return value
        }
        guard let defaultValue else { throw WovenNoteCLIError.missingArgument(flag) }
        return defaultValue
    }

    mutating func optionalInteger(for flag: String) throws -> Int? {
        guard let raw = value(for: flag) else { return nil }
        guard let value = Int(raw) else { throw WovenNoteCLIError.invalidInteger(flag) }
        return value
    }

    mutating func style(required: Bool = false) throws -> NoteParagraphStyle {
        guard let raw = value(for: "--style") else {
            if required { throw WovenNoteCLIError.missingArgument("--style") }
            return .paragraph
        }
        guard let style = NoteParagraphStyle(rawValue: raw) else {
            throw WovenNoteCLIError.invalidStyle(raw)
        }
        return style
    }
}

private extension NoteEditingRequest {
    static func applying(
        noteID: String,
        revision: String?,
        _ operation: NoteEditOperation
    ) -> NoteEditingRequest {
        NoteEditingRequest(
            command: .apply,
            noteID: noteID,
            expectedRevision: revision,
            operations: [operation]
        )
    }
}

private enum WovenNoteCLIError: LocalizedError {
    case missingNoteID
    case missingEnvironment(String)
    case missingArgument(String)
    case invalidInteger(String)
    case invalidStyle(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingNoteID: "No note is attached. Set WOVEN_NOTE_ID or pass --note-id."
        case .missingEnvironment(let key): "Missing environment variable: \(key)"
        case .missingArgument(let value): "Missing argument: \(value)"
        case .invalidInteger(let flag): "Expected an integer after \(flag)."
        case .invalidStyle(let style): "Unknown paragraph style: \(style)"
        case .unknownCommand(let command): "Unknown command: \(command)"
        }
    }
}

private enum WovenNoteSocketError: LocalizedError {
    case pathTooLong
    case requestTooLarge
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong: "The Woven Matter note socket path is too long."
        case .requestTooLarge: "The Woven Matter note request exceeded 4 MB."
        case .system(let code): String(cString: strerror(code))
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw WovenNoteSocketError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes.map(UInt8.init(bitPattern:)))
    }
    return address
}

private func readMessage(from descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else { throw WovenNoteSocketError.system(errno) }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= 4 * 1_024 * 1_024 else { throw WovenNoteSocketError.requestTooLarge }
    }
    return data
}

private func writeMessage(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { throw WovenNoteSocketError.system(errno) }
            offset += count
        }
    }
}
