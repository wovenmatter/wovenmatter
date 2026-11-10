import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum PortableMIME {
  /// The file extension a MIME type conventionally uses. Apple platforms ask
  /// UTType; Linux uses the common types the library exchanges.
  public static func preferredFilenameExtension(for mimeType: String) -> String? {
    #if canImport(UniformTypeIdentifiers)
    return UTType(mimeType: mimeType)?.preferredFilenameExtension
    #else
    let base = mimeType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    return [
      "text/plain": "txt", "text/html": "html", "text/css": "css", "text/csv": "csv", "text/markdown": "md",
      "text/javascript": "js", "application/javascript": "js", "application/json": "json", "application/xml": "xml",
      "text/xml": "xml", "application/pdf": "pdf", "application/zip": "zip", "application/gzip": "gz",
      "application/x-tar": "tar", "application/vnd.sqlite3": "sqlite", "application/x-sqlite3": "sqlite",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
      "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
      "image/png": "png", "image/jpeg": "jpeg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic",
      "image/svg+xml": "svg", "image/tiff": "tiff", "image/bmp": "bmp", "audio/mpeg": "mp3", "audio/wav": "wav",
      "audio/x-wav": "wav", "audio/mp4": "m4a", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm"
    ][base]
    #endif
  }
}
