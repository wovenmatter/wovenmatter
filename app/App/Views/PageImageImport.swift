import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore
import WovenMatterLibraryStore

/// Images on a Page are stored in the Page itself, made small enough to fit
/// beside its writing. They come from the library's saved images, from Files,
/// or from Photos when this Mac has a Photos library.
@MainActor enum PageImageImport {
    enum Source: CaseIterable {
        case library, files, photos

        var menuTitle: String {
            switch self {
            case .library: "From Library…"
            case .files: "From Files…"
            case .photos: "From Photos…"
            }
        }
    }

    /// Only sources that have something to offer on this Mac.
    static func sources(model: ApplicationModel) -> [Source] {
        var sources: [Source] = []
        if !libraryImages(model).isEmpty { sources.append(.library) }
        sources.append(.files)
        if photosLibraryExists { sources.append(.photos) }
        return sources
    }

    static func libraryImages(_ model: ApplicationModel) -> [SavedArtifactLibraryItem] {
        model.library.savedArtifacts.items.filter { PageImage.mediaTypes.contains($0.manifest.mediaType) || $0.manifest.mediaType == "image/heic" }
    }

    static var photosLibraryExists: Bool {
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pictures.path)) ?? []
        return names.contains { $0.hasSuffix(".photoslibrary") }
    }

    static func chooseFile() async throws -> PageImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (metadata.fileSize ?? Int.max) <= 50_000_000 else { throw NoteDocumentSafetyError.tooLarge }
        return try image(from: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    static func image(from library: SavedArtifactLibraryItem, model: ApplicationModel) async throws -> PageImage? {
        guard let url = await model.library.savedArtifacts.prepare(library) else { return nil }
        return try image(from: Data(contentsOf: url), name: library.manifest.title)
    }

    /// Keeps a small PNG, JPEG or GIF as it is. Anything larger is scaled down
    /// and stored as JPEG until it fits.
    static func image(from data: Data, name: String?) throws -> PageImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil else {
            throw NoteDocumentSafetyError.unsupportedFormat
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int, height = properties?[kCGImagePropertyPixelHeight] as? Int
        let alt = name.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let direct: String? = type.conforms(to: .png) ? "image/png" : type.conforms(to: .jpeg) ? "image/jpeg"
            : type.conforms(to: .gif) ? "image/gif" : nil
        if let direct, data.count <= PageImage.maximumBytes {
            return PageImage(mediaType: direct, bytes: data, alt: alt, width: width, height: height)
        }
        for size in [2000, 1600, 1200, 900, 600, 400] {
            for quality in [0.8, 0.6] {
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { continue }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { continue }
                if output.length <= PageImage.maximumBytes {
                    return PageImage(mediaType: "image/jpeg", bytes: output as Data, alt: alt, width: image.width, height: image.height)
                }
            }
        }
        throw NoteDocumentSafetyError.tooLarge
    }

    static func failure(_ error: Error) -> String {
        if case NoteDocumentSafetyError.tooLarge = error {
            return "The image doesn't fit on this Page. Each Page holds about 1 MB, shared by its images and writing."
        }
        return "The image could not be added. Choose a PNG, JPEG, GIF or HEIC image."
    }
}

/// An image stored in the Page.
struct PageImageView: View {
    @Environment(\.wovenTheme) private var theme
    let image: PageImage?

    var body: some View {
        if let image, let bytes = image.bytes, let picture = NSImage(data: bytes) {
            Image(nsImage: picture)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: min(CGFloat(image.width ?? 900), 900), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(image.alt ?? "Image")
        } else {
            Label("This image can't be shown.", systemImage: "photo")
                .font(.system(size: 12)).foregroundStyle(WovenPalette.mutedForeground)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.palette.workspace))
        }
    }
}

/// The Photos and library pickers a Page's Image menu opens.
struct PageImagePickers: ViewModifier {
    @Bindable var model: ApplicationModel
    @Binding var viewState: CanvasViewState
    let inserter: PageComponentInserter
    @State private var photo: PhotosPickerItem?
    /// Kept apart from the picker's presentation, which can close before the choice arrives.
    @State private var photoPosition: PagePosition?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: Binding(get: { viewState.photoPickerPosition != nil },
                                               set: { if !$0 { viewState.photoPickerPosition = nil } }),
                          selection: $photo, matching: .images)
            .onChange(of: viewState.photoPickerPosition) { _, position in if let position { photoPosition = position } }
            .onChange(of: photo) { _, item in
                guard let item, let position = photoPosition else { return }
                photo = nil; photoPosition = nil; viewState.photoPickerPosition = nil
                viewState.importingImage = true
                Task {
                    defer { viewState.importingImage = false }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { return }
                        inserter.addImage(try PageImageImport.image(from: data, name: nil), position: position)
                    } catch { viewState.error = PageImageImport.failure(error) }
                }
            }
            .sheet(isPresented: Binding(get: { viewState.libraryImagePickerPosition != nil },
                                        set: { if !$0 { viewState.libraryImagePickerPosition = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Add an image from your library").font(.headline)
                        Spacer()
                        Button("Done") { viewState.libraryImagePickerPosition = nil }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(PageImageImport.libraryImages(model)) { item in
                                Button {
                                    let position = viewState.libraryImagePickerPosition ?? .init()
                                    viewState.libraryImagePickerPosition = nil
                                    viewState.importingImage = true
                                    Task {
                                        defer { viewState.importingImage = false }
                                        do {
                                            if let image = try await PageImageImport.image(from: item, model: model) {
                                                inserter.addImage(image, position: position)
                                            }
                                        } catch { viewState.error = PageImageImport.failure(error) }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "photo")
                                        Text(item.manifest.title.isEmpty ? "Untitled image" : item.manifest.title)
                                        Spacer()
                                        Text(item.workspaceName).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(WovenQuietButtonStyle())
                            }
                        }
                    }
                }.padding(24).frame(width: 480, height: 420)
            }
            .task { await model.library.savedArtifacts.refresh() }
    }
}
