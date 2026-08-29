import CryptoKit
import Foundation
import WovenMatterCore

struct MessageAttachmentStore: Sendable {
  private let blobsDirectory: URL

  init(supportDirectory: URL) throws {
    blobsDirectory = supportDirectory
      .appending(path: "message-attachments", directoryHint: .isDirectory)
      .appending(path: "blobs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: blobsDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: blobsDirectory.path
    )
  }

  func stage(fileURL: URL, mimeType: String) throws -> AgentFileAttachmentDraft {
    let cleanURL = fileURL.standardizedFileURL
    let fileName = cleanURL.lastPathComponent.isEmpty
      ? "Attachment" : cleanURL.lastPathComponent
    guard let values = try? cleanURL.resourceValues(forKeys: [.isRegularFileKey]),
          values.isRegularFile == true else {
      throw AgentMessageAttachmentError.unreadableFile(fileName)
    }
    guard let data = try? Data(contentsOf: cleanURL, options: [.mappedIfSafe]) else {
      throw AgentMessageAttachmentError.unreadableFile(fileName)
    }
    let size = Int64(data.count)
    guard size <= AgentMessageAttachmentLimits.maximumFileBytes else {
      throw AgentMessageAttachmentError.fileTooLarge(
        name: fileName,
        maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes
      )
    }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let storedURL = url(contentHash: hash)
    if !FileManager.default.fileExists(atPath: storedURL.path) {
      try data.write(to: storedURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: storedURL.path
      )
    }
    return AgentFileAttachmentDraft(
      kind: mimeType.lowercased().hasPrefix("image/") ? .image : .file,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: size,
      contentHash: hash,
      localURL: storedURL
    )
  }

  func url(contentHash: String) -> URL {
    blobsDirectory.appending(path: contentHash, directoryHint: .notDirectory)
  }
}
