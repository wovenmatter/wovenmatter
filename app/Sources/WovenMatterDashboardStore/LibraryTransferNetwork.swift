import Foundation
import WovenMatterCore

private final class LibraryTransferNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class LibraryTransferNetwork: @unchecked Sendable {
  private let session: URLSession
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 180
    session = URLSession(configuration: config, delegate: LibraryTransferNoRedirects(), delegateQueue: nil)
  }
  public func request<T: Decodable & Sendable>(_ endpoint: URL, path: String, secret: String? = nil, body: Data? = nil) async throws -> T {
    guard CompanionPairingPayload.isValidEndpoint(endpoint), path.hasPrefix("v1/library-transfer/"),
          !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw invalid }
    var request = URLRequest(url: endpoint.appending(path: path))
    request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let secret { request.setValue(secret, forHTTPHeaderField: "X-Woven-Transfer-Secret") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 16 * 1_024 * 1_024 else { throw invalid }
    var data = Data()
    for try await byte in bytes { guard data.count < 16 * 1_024 * 1_024 else { throw invalid }; data.append(byte) }
    guard response.statusCode == 200 else {
      if let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data) { throw error }
      throw invalid
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  private var invalid: CompanionAPIError { .init(code: "transfer_connection", message: "The other Mac could not complete this database transfer request. Reconnect it and retry the saved transfer.") }
}
