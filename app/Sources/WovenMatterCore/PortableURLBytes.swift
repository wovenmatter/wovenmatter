#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

/// Linux Foundation lacks `URLSession.bytes(for:)`. This streams a response the
/// same way for the few callers that bound or cancel a body while reading it.
/// Each request gets a private session from the caller's configuration whose
/// delegate refuses redirects, so a redirect fails closed rather than following.
public struct PortableURLBytes: AsyncSequence, Sendable {
  public typealias Element = UInt8
  public let task: URLSessionDataTask
  fileprivate let chunks: AsyncThrowingStream<Data, any Error>

  public struct AsyncIterator: AsyncIteratorProtocol {
    fileprivate var base: AsyncThrowingStream<Data, any Error>.AsyncIterator
    fileprivate var buffer = [UInt8]()
    fileprivate var index = 0
    public mutating func next() async throws -> UInt8? {
      while index >= buffer.count {
        guard let chunk = try await base.next() else { return nil }
        buffer = [UInt8](chunk); index = 0
      }
      defer { index += 1 }
      return buffer[index]
    }
  }

  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: chunks.makeAsyncIterator()) }
}

private final class PortableURLBytesDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var response: CheckedContinuation<URLResponse, any Error>?
  let chunks: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  override init() {
    (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    super.init()
  }

  func awaitResponse(_ continuation: CheckedContinuation<URLResponse, any Error>) {
    lock.withLock { response = continuation }
  }

  private func takeResponse() -> CheckedContinuation<URLResponse, any Error>? {
    lock.withLock { defer { response = nil }; return response }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    takeResponse()?.resume(returning: response)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    if let error {
      takeResponse()?.resume(throwing: error)
      continuation.finish(throwing: error)
    } else {
      takeResponse()?.resume(throwing: URLError(.badServerResponse))
      continuation.finish()
    }
  }
}

extension URLSession {
  public func bytes(for request: URLRequest) async throws -> (PortableURLBytes, URLResponse) {
    let delegate = PortableURLBytesDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    let bytes = PortableURLBytes(task: task, chunks: delegate.chunks)
    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.awaitResponse(continuation)
        task.resume()
        session.finishTasksAndInvalidate()
      }
    } onCancel: { task.cancel() }
    return (bytes, response)
  }

  public func bytes(from url: URL) async throws -> (PortableURLBytes, URLResponse) {
    try await bytes(for: URLRequest(url: url))
  }
}
#endif
