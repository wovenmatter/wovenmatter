import Foundation

public enum BoundedHTTPResponse {
  public static func data(
    for request: URLRequest,
    using session: URLSession,
    maximumBytes: Int
  ) async throws -> (Data, URLResponse) {
    precondition(maximumBytes > 0)
    let delegate = BoundedHTTPDownloadDelegate(maximumBytes: maximumBytes)
    do {
      let (fileURL, response) = try await session.download(for: request, delegate: delegate)
      if let terminalError = delegate.terminalError { throw terminalError }
      guard response.url == request.url else { throw BoundedHTTPError.redirectDenied }
      guard response.expectedContentLength <= Int64(maximumBytes) else {
        throw BoundedHTTPError.responseTooLarge(maximumBytes: maximumBytes)
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      guard let fileSize = attributes[.size] as? NSNumber,
            fileSize.int64Value <= Int64(maximumBytes) else {
        throw BoundedHTTPError.responseTooLarge(maximumBytes: maximumBytes)
      }
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard data.count <= maximumBytes else {
        throw BoundedHTTPError.responseTooLarge(maximumBytes: maximumBytes)
      }
      return (data, response)
    } catch {
      if let terminalError = delegate.terminalError { throw terminalError }
      throw error
    }
  }
}

private final class BoundedHTTPDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let maximumBytes: Int64
  private let lock = NSLock()
  private var storedTerminalError: BoundedHTTPError?

  init(maximumBytes: Int) {
    self.maximumBytes = Int64(maximumBytes)
  }

  var terminalError: BoundedHTTPError? {
    lock.lock()
    defer { lock.unlock() }
    return storedTerminalError
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes else { return }
    record(.responseTooLarge(maximumBytes: Int(maximumBytes)))
    downloadTask.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    record(.redirectDenied)
    completionHandler(nil)
  }

  private func record(_ error: BoundedHTTPError) {
    lock.lock()
    defer { lock.unlock() }
    if storedTerminalError == nil { storedTerminalError = error }
  }
}
