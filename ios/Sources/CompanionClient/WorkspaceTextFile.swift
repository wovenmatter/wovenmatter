import Foundation

/// Bounded byte windows let agents inspect saved execution output without loading
/// an entire log. Exact bytes remain available when a window splits UTF-8.
public struct WorkspaceTextFileWindow: Codable, Equatable, Sendable {
  public var content: String
  public var requestedOffset: Int
  public var offset: Int
  public var nextOffset: Int
  public var fileSize: Int
  public var byteCount: Int
  public var eof: Bool
  public var truncated: Bool
  public var lossyUTF8: Bool
  public var bytesBase64: String?
}
public enum WorkspaceTextFile {
  public static let maximumReadBytes = 1_024 * 1_024
  public static let defaultWindowBytes = 65_536
  public enum Failure: Error, LocalizedError {
    case invalidOffset, invalidLimit, notRegularFile
    public var errorDescription: String? {
      switch self {
      case .invalidOffset: "The byte offset must be a nonnegative integer."
      case .invalidLimit: "The byte limit must be between 1 and 1048576."
      case .notRegularFile: "Choose a regular file in this workspace."
      }
    }
  }
  public static func read(_ url: URL, offset: Int? = nil, limit: Int? = nil) throws -> WorkspaceTextFileWindow {
    try Task.checkCancellation()
    guard (offset ?? 0) >= 0 else { throw Failure.invalidOffset }
    if let limit, !(1...maximumReadBytes).contains(limit) { throw Failure.invalidLimit }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { throw Failure.notRegularFile }
    let requested = offset ?? 0, start = min(requested, size)
    let count = limit ?? (offset == nil && size <= maximumReadBytes ? max(1, size) : defaultWindowBytes)
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(start))
    let bytes = try handle.read(upToCount: min(count, size - start)) ?? Data()
    let decoded = String(data: bytes, encoding: .utf8), next = start + bytes.count
    return .init(content: decoded ?? String(decoding: bytes, as: UTF8.self), requestedOffset: requested,
      offset: start, nextOffset: next, fileSize: size, byteCount: bytes.count, eof: next >= size,
      truncated: start > 0 || next < size, lossyUTF8: decoded == nil,
      bytesBase64: decoded == nil ? bytes.base64EncodedString() : nil)
  }
}
