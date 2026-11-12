// The Woven VM is macOS only (Virtualization framework); Linux library builds skip it.
#if os(macOS)
import Darwin
import Foundation

/// The helper's control API is HTTP/1.1 with JSON bodies on a 0600 Unix socket,
/// one request per connection, so any client (the app, the Node bots runtime,
/// curl --unix-socket) can use it without a library.
public enum WovenVMControlHTTP {
    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var body: Data
        public init(method: String, path: String, body: Data = Data()) {
            self.method = method
            self.path = path
            self.body = body
        }
    }

    public static let maximumBody = 1 << 20

    /// Returns nil while the request is still incomplete.
    public static func parseRequest(_ data: Data) throws -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw WovenVMError.invalid("Request headers are too large.") }
            return nil
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            throw WovenVMError.invalid("Request headers are not UTF-8.")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw WovenVMError.invalid("Malformed request line.") }
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let parsed = Int(value), parsed >= 0, parsed <= maximumBody else {
                    throw WovenVMError.invalid("The request body is too large.")
                }
                length = parsed
            } else if name == "transfer-encoding" {
                throw WovenVMError.invalid("Chunked requests are not supported.")
            }
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]),
                       body: Data(data[bodyStart..<bodyStart + length]))
    }

    public static func response(status: Int, body: Data) -> Data {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request",
                      404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error",
                      503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    public static func parseResponse(_ data: Data) throws -> (status: Int, body: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            throw WovenVMError.unavailable("The VM helper closed the connection.")
        }
        let parts = head.prefix { $0 != "\r" }.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw WovenVMError.unavailable("The VM helper sent a malformed reply.") }
        return (status, Data(data[end.upperBound...]))
    }

    /// The error body every non-2xx reply carries.
    public struct ErrorBody: Codable, Sendable { public var error: String }
}
#endif
