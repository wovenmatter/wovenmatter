import AppKit
import ImageIO
import UniformTypeIdentifiers
import WovenMatterCore

@MainActor enum PageImageImport {
    static func importImage(model: ApplicationModel, folderID: String?) async throws -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (metadata.fileSize ?? Int.max) <= 20_000_000 else { throw NoteDocumentSafetyError.tooLarge }
        let original = try Data(contentsOf: url)
        let type = url.pathExtension.lowercased()
        var bytes = original
        var mime = type == "png" ? "image/png" : type == "gif" ? "image/gif" : "image/jpeg"
        if bytes.count > 650_000 {
            guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { throw NoteDocumentSafetyError.unsupportedFormat }
            for size in [1600, 1000, 600] {
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { continue }
                let output = NSMutableData()
                let format = type == "png" ? UTType.png : UTType.jpeg
                guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(destination) {
                    bytes = output as Data; mime = type == "png" ? "image/png" : "image/jpeg"
                    if bytes.count <= 650_000 { break }
                }
            }
        }
        guard bytes.count <= 650_000 else { throw NoteDocumentSafetyError.tooLarge }
        guard let id = await model.createNote(folderID: folderID, kind: .html),
              let asset = model.workspaceOverview?.notes.first(where: { $0.id == id }) else { throw ArtifactInputError.unavailable }
        var document = NoteDocument.decode(asset.content)
        document.html = "<style>body{padding:0;display:grid;place-items:center}img{max-width:100%;height:auto}</style><img alt=\"Imported image\" src=\"data:\(mime);base64,\(bytes.base64EncodedString())\">"
        model.updateNoteDraft(note: asset, title: url.deletingPathExtension().lastPathComponent, content: try document.encoded())
        return id
    }
}
