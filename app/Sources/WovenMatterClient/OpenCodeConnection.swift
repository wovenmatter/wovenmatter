import Foundation

public struct OpenCodeConnection: Equatable, Sendable {
    public static let supportedVersion = "0.0.0-beta-19278"
    public static let upstreamCommit = "be41bc4e7de76637f4c7a94d6110637270bfff37"
    /// Stable identity follows the registration file or explicitly saved remote
    /// connection, never a port, process ID, or replaceable service instance ID.
    public let identity: String
    public let url: URL
    public let username: String
    public let password: String
    public let registration: URL?
    public let pid: Int?
    public let version: String?
    public let servicePathPrefix: String
    private let bearerToken: String?
    public var isRemoteWorkspaceProxy: Bool { bearerToken != nil }

    public init(identity: String, url: URL, username: String = "opencode", password: String,
                registration: URL? = nil, pid: Int? = nil, version: String? = nil,
                servicePathPrefix: String = "", bearerToken: String? = nil) throws {
        guard ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw OpenCodeError.message("Use an HTTP or HTTPS server origin without embedded credentials or a path.")
        }
        if let bearerToken {
            guard !bearerToken.isEmpty, !bearerToken.contains(where: { $0.isNewline }),
                  identity.hasPrefix("remote-workspace:"),
                  UUID(uuidString: String(identity.dropFirst("remote-workspace:".count))) != nil,
                  url.scheme == "http", ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host ?? ""),
                  servicePathPrefix == "/v1/workspace-instances/opencode", registration == nil else {
                throw OpenCodeError.message("Remote OpenCode must use its workspace's authenticated SSH loopback proxy.")
            }
        } else if !servicePathPrefix.isEmpty {
            throw OpenCodeError.message("A service path requires workspace proxy authorization.")
        }
        self.servicePathPrefix = servicePathPrefix
        self.bearerToken = bearerToken
        self.identity = identity; self.url = url; self.username = username; self.password = password
        self.registration = registration; self.pid = pid; self.version = version
    }
    public static func registrationURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        URL(fileURLWithPath: environment["XDG_STATE_HOME"] ?? home.appending(path: ".local/state").path)
            .appending(path: "opencode/service.json")
    }
    public static func discover(file: URL = registrationURL()) throws -> Self {
        guard let data = try? Data(contentsOf: file), data.count <= 65_536 else {
            throw OpenCodeError.message("The local OpenCode v2 service is not running. Connect to OpenCode in Local Agent Workspace.")
        }
        let info = try OpenCodeValue.decode(data)
        guard var components = URLComponents(string: info["url"].text),
              let pid = info["pid"].number, pid > 0, pid <= Double(Int32.max), pid.rounded() == pid,
              let password = info["password"].string, !password.isEmpty else {
            throw OpenCodeError.message("The OpenCode service registration is incomplete or unauthenticated.")
        }
        if components.host == "0.0.0.0" { components.host = "127.0.0.1" }
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host ?? ""),
              let url = components.url else { throw OpenCodeError.message("Local OpenCode registration must name a loopback server.") }
        return try Self(identity: "local:" + file.standardizedFileURL.path, url: url, password: password,
                        registration: file, pid: Int(pid), version: info["version"].string)
    }
    /// OpenCode consumes this token at startup and removes it from browser history.
    /// Keep this URL out of logs and persistent Woven Matter settings.
    public var browserURL: URL {
        // Workspace API credentials must never be embedded in browser URLs.
        if isRemoteWorkspaceProxy { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "auth_token", value: Data("\(username):\(password)".utf8).base64EncodedString())]
        return components.url!
    }
    public var authorization: String {
        if let bearerToken { return "Bearer " + bearerToken }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// Server-selected redirects must not move authenticated requests or mutations.
private final class OpenCodeSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct OpenCodeHTTPClient: Sendable {
    public let connection: OpenCodeConnection
    private let session: URLSession
    public init(connection: OpenCodeConnection, session: URLSession? = nil) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 86_400
        config.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: config, delegate: OpenCodeSessionDelegate(), delegateQueue: nil)
    }
    public static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    public func request(_ method: String = "GET", _ path: String,
                        query: [String: String] = [:], body: OpenCodeValue? = nil) throws -> URLRequest {
        guard path.hasPrefix("/api/"), !path.contains(".."),
              var components = URLComponents(url: connection.url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeError.message("Invalid OpenCode request path.")
        }
        components.percentEncodedPath = connection.servicePathPrefix + path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw OpenCodeError.message("Invalid OpenCode request URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
    public func call(_ method: String = "GET", _ path: String,
                     query: [String: String] = [:], body: OpenCodeValue? = nil) async throws -> OpenCodeValue {
        let (bytes, response) = try await session.bytes(for: request(method, path, query: query, body: body))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            bytes.task.cancel()
            throw OpenCodeError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 32 * 1_024 * 1_024 else { bytes.task.cancel(); throw OpenCodeError.message("OpenCode response exceeds the 32 MB limit. Use a smaller page or file.") }
            data.append(byte)
        }
        return data.isEmpty ? .null : try OpenCodeValue.decode(data)
    }
    public func readFile(path: String, query: [String: String]) async throws -> (Data, String) {
        var request = try request("GET", "/api/fs/read/" + Self.segment(path), query: query)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw OpenCodeError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 25 * 1_024 * 1_024 else { throw OpenCodeError.message("File preview exceeds 25 MB.") }
            data.append(byte)
        }
        return (data, http.mimeType ?? "application/octet-stream")
    }
    public func health() async throws -> OpenCodeValue {
        let health = try await call("GET", "/api/health")
        let version = health["version"].text
        guard version == OpenCodeConnection.supportedVersion else { throw OpenCodeError.incompatible(version) }
        guard health["healthy"].bool,
              connection.pid == nil || health["pid"].number == Double(connection.pid!),
              connection.version == nil || connection.version == version else {
            throw OpenCodeError.message("OpenCode service identity changed. Discover the service again.")
        }
        return health
    }
    public func events(_ path: String, query: [String: String] = [:],
                       receive: @escaping @Sendable (OpenCodeValue) async throws -> Void) async throws {
        var request = try request("GET", path, query: query)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The durable log can legitimately be silent while a session is idle.
        // HTTP snapshots retain their short timeout; stream silence is not a
        // connection failure. A closed socket still triggers normal recovery.
        request.timeoutInterval = 86_400
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenCodeError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
            throw OpenCodeError.malformedStream
        }
        var parser = OpenCodeSSEParser()
        for try await byte in bytes {
            try Task.checkCancellation()
            for value in try parser.append(byte) { try await receive(value) }
        }
        // A partial frame is never accepted or acknowledged at EOF.
        if parser.hasPartialFrame { throw OpenCodeError.malformedStream }
    }
}

public struct OpenCodeSSEParser: Sendable {
    private var line = Data()
    private var data = Data()
    private var carriageReturn = false
    private var failure = false
    public init() {}
    public var hasPartialFrame: Bool { !line.isEmpty || !data.isEmpty }
    public mutating func append(_ byte: UInt8) throws -> [OpenCodeValue] {
        if carriageReturn && byte == 10 { carriageReturn = false; return [] }
        carriageReturn = byte == 13
        guard byte == 10 || byte == 13 else {
            guard line.count + data.count < 8 * 1_024 * 1_024 else { throw OpenCodeError.malformedStream }
            line.append(byte); return []
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !failure else { throw OpenCodeError.malformedStream }
            guard !data.isEmpty else { return [] }
            defer { data.removeAll(keepingCapacity: true) }
            if data.last == 10 { data.removeLast() }
            var value = try OpenCodeValue.decode(data)
            // Effect's encoded JSON schema can itself be a JSON string.
            if let encoded = value.string { value = try OpenCodeValue.decode(Data(encoded.utf8)) }
            return [value]
        }
        if line.starts(with: Data("event: effect/httpapi/stream/failure".utf8)) { failure = true }
        if line.starts(with: Data("data:".utf8)) {
            let offset = line.count > 5 && line[5] == 32 ? 6 : 5
            data.append(line.dropFirst(offset)); data.append(10)
        }
        return []
    }
}
