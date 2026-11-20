import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// An answer from OpenCode's API that was not a success.
struct OpenCodeHTTPError: Error, CustomStringConvertible {
  var status: Int
  var message: String

  var description: String { message.isEmpty ? "OpenCode answered HTTP \(status)." : message }
}

/// OpenCode's HTTP API on one server process: JSON requests and its event stream.
struct OpenCodeClient: Sendable {
  let base: URL
  private let authorization: String
  private let session: URLSession

  init(base: URL, password: String) {
    self.base = base
    authorization = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration)
  }

  /// Calls one endpoint. `path` starts with `/api/`; segments are already encoded.
  @discardableResult
  func call(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: OpenCodeJSON? = nil) async throws
    -> OpenCodeJSON
  {
    let request = try request(method, path, query: query, body: body)
    let (data, status) = try await perform(request)
    guard (200...299).contains(status) else {
      let message = (try? OpenCodeJSON.decode(data))?["message"].string ?? String(decoding: data.prefix(500), as: UTF8.self)
      throw OpenCodeHTTPError(status: status, message: message)
    }
    return data.isEmpty ? .null : try OpenCodeJSON.decode(data)
  }

  /// The event stream at `path`, until it ends or the task reading it is cancelled.
  func events(_ path: String) throws -> AsyncThrowingStream<OpenCodeJSON, any Error> {
    var request = try request("GET", path)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 365 * 86_400
    let (stream, continuation) = AsyncThrowingStream<OpenCodeJSON, any Error>.makeStream()
    let reader = OpenCodeEventReader(continuation: continuation)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 365 * 86_400
    configuration.timeoutIntervalForResource = 365 * 86_400
    let streamSession = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
    let task = streamSession.dataTask(with: request)
    continuation.onTermination = { _ in
      task.cancel()
      streamSession.invalidateAndCancel()
    }
    task.resume()
    return stream
  }

  static func segment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
  }

  private func request(_ method: String, _ path: String, query: [String: String] = [:], body: OpenCodeJSON? = nil) throws
    -> URLRequest
  {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw OpenCodeHTTPError(status: 0, message: "OpenCode's address is not valid.")
    }
    components.percentEncodedPath = path
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else { throw OpenCodeHTTPError(status: 0, message: "OpenCode's address is not valid.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    return request
  }

  private func perform(_ request: URLRequest) async throws -> (Data, Int) {
    let session = session
    return try await withCheckedThrowingContinuation { continuation in
      session.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
      }.resume()
    }
  }
}

/// Feeds a streaming response through the SSE parser. Streams with a
/// delegate because `URLSession.bytes(for:)` is not on Linux.
private final class OpenCodeEventReader: NSObject, URLSessionDataDelegate, Sendable {
  private let continuation: AsyncThrowingStream<OpenCodeJSON, any Error>.Continuation
  private let parser = Mutex(OpenCodeSSEParser())

  init(continuation: AsyncThrowingStream<OpenCodeJSON, any Error>.Continuation) {
    self.continuation = continuation
  }

  // The status is checked from the task rather than in the response callback,
  // whose signature differs between Darwin and Linux.
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard Self.status(dataTask) == 200 else { return }
    for event in parser.withLock({ $0.append(data) }) { continuation.yield(event) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    if let error {
      continuation.finish(throwing: error)
    } else if Self.status(task) != 200 {
      continuation.finish(throwing: OpenCodeHTTPError(status: Self.status(task), message: "OpenCode refused its event stream."))
    } else {
      continuation.finish()
    }
    session.finishTasksAndInvalidate()
  }

  private static func status(_ task: URLSessionTask) -> Int { (task.response as? HTTPURLResponse)?.statusCode ?? 0 }
}
