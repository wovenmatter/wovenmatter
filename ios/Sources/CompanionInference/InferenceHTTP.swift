import Foundation

public enum InferenceHTTPEvent: Sendable { case response(Int); case line(String) }
public protocol InferenceHTTPTransport: Sendable {
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error>
}

/// Redirects never forward API keys or device grants to a different endpoint.
public final class InferenceURLSessionTransport: NSObject, InferenceHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
  public override init() { super.init() }
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
  public func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 180
    configuration.timeoutIntervalForResource = 1800
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await session.bytes(for: request) }
    catch { session.invalidateAndCancel(); if Task.isCancelled { throw CancellationError() }; throw InferenceError.connectionFailed }
    guard let response = response as? HTTPURLResponse else { session.invalidateAndCancel(); throw InferenceError.malformedResponse }
    return AsyncThrowingStream { continuation in
      let task = Task {
        defer { session.invalidateAndCancel() }
        continuation.yield(.response(response.statusCode))
        do {
          // URLSession.lines is unbounded for one line. Enforce byte limits before UTF-8 parsing.
          var line = Data(), total = 0
          for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= 32 * 1024 * 1024, line.count <= 4 * 1024 * 1024 else { throw InferenceError.responseTooLarge }
            if byte == 10 {
              if line.last == 13 { line.removeLast() }
              guard let value = String(data: line, encoding: .utf8) else { throw InferenceError.malformedResponse }
              continuation.yield(.line(value)); line.removeAll(keepingCapacity: true)
            } else { line.append(byte) }
          }
          if !line.isEmpty {
            guard let value = String(data: line, encoding: .utf8) else { throw InferenceError.malformedResponse }
            continuation.yield(.line(value))
          }
          continuation.finish()
        } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
        catch let error as InferenceError { continuation.finish(throwing: error) }
        catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : InferenceError.connectionFailed) }
      }
      continuation.onTermination = { @Sendable _ in task.cancel(); session.invalidateAndCancel() }
    }
  }
}
