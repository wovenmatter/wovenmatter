import Foundation

/// The injectable wire boundary keeps protocol tests entirely provider-free.
protocol OpenClawGatewaySocket: Sendable {
  func start() async
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func close() async
}

final class OpenClawURLSessionSocket: OpenClawGatewaySocket, @unchecked Sendable {
  private let session = URLSession(configuration: .ephemeral)
  private let socket: URLSessionWebSocketTask

  init(request: URLRequest) {
    socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 32 * 1_024 * 1_024
  }

  func start() async { socket.resume() }
  func send(_ data: Data) async throws {
    guard let text = String(data: data, encoding: .utf8) else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    try await socket.send(.string(text))
  }
  func receive() async throws -> Data {
    switch try await socket.receive() {
    case .data(let data): return data
    case .string(let text): return Data(text.utf8)
    @unknown default: throw OpenClawGatewayClientError.malformedFrame
    }
  }
  func close() async {
    socket.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}
