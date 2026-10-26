import AppKit
import WebKit
import WovenMatterCore

/// A private ephemeral browser, separate from the user's browser tabs.
@MainActor final class ConversationHTMLPreview {
    private let coordinator = ConversationHTMLWebCoordinator()
    private var waiter: CheckedContinuation<Void, any Error>?
    private var snapshotWaiter: CheckedContinuation<NSImage, any Error>?
    private var contentHeight: CGFloat = 400

    func capture(_ input: GatewayJSONValue) async throws -> GatewayJSONValue {
        guard let values = input.objectValue, values["action"]?.stringValue == "preview",
              let html = values["html"]?.stringValue else { throw WorkspaceToolError.invalid("Provide HTML to preview.") }
        _ = try ConversationHTMLPage(html: html, title: "Preview", height: 400)
        let width = values["width"]?.intValue ?? 728
        let appearance = values["appearance"]?.stringValue ?? "dark"
        guard (values["width"] == nil || values["width"]?.intValue != nil),
              (values["appearance"] == nil || values["appearance"]?.stringValue != nil),
              (240...1600).contains(width), ["light", "dark"].contains(appearance) else {
            throw WorkspaceToolError.invalid("Preview width must be 240–1600 pixels and appearance light or dark.")
        }
        let view = coordinator.makeWebView()
        view.setValue(true, forKey: "drawsBackground")
        view.underPageBackgroundColor = NSColor((appearance == "dark" ? DashboardTheme.dark : .green).palette.workspace)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        defer { coordinator.stop(view) }
        coordinator.onHeight = { [weak self] in self?.contentHeight = $0 }
        coordinator.onReady = { [weak self] in self?.finish(nil) }
        coordinator.onFailure = { [weak self] in self?.finish($0) }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { self?.finish(WorkspaceToolError.invalid("HTML preview timed out.")) }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { () async throws -> GatewayJSONValue in
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                if Task.isCancelled { finish(CancellationError()); return }
                coordinator.apply(html: html, theme: ConversationHTMLTheme.value(appearance == "dark" ? .dark : .green), to: view)
            }
            try await Task.sleep(for: .milliseconds(250))
            let capturedHeight = min(2000, max(80, Int(ceil(contentHeight))))
            view.frame.size.height = CGFloat(capturedHeight)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            let image = try await withCheckedThrowingContinuation { continuation in
                snapshotWaiter = continuation
                if Task.isCancelled { finish(CancellationError()); return }
                view.takeSnapshot(with: configuration) { [weak self] image, error in
                    guard let self, let waiting = self.snapshotWaiter else { return }
                    self.snapshotWaiter = nil
                    if let image { waiting.resume(returning: image) }
                    else { waiting.resume(throwing: error ?? WorkspaceToolError.invalid("The page could not be captured.")) }
                }
            }
            try Task.checkCancellation()
            let (png, pixels) = try boundedPNG(image)
            let metadata: [String: Any] = ["width": width, "contentHeight": Int(ceil(contentHeight)),
                "capturedHeight": capturedHeight, "consoleMessages": coordinator.consoleMessages,
                "missingImages": values["missingImages"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                "screenshotWidth": pixels.width, "screenshotHeight": pixels.height]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
            return .object(["content": .array([
                .object(["type": .string("text"), "text": .string(json)]),
                .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])
            ])])
        } onCancel: { Task { @MainActor [weak self] in self?.finish(CancellationError()) } }
    }

    private func finish(_ error: (any Error)?) {
        if let waiter {
            self.waiter = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
        if let error, let snapshotWaiter { self.snapshotWaiter = nil; snapshotWaiter.resume(throwing: error) }
    }

    /// Keep the complete screenshot when image-heavy pages exceed the existing
    /// MCP response budget; reduce pixel resolution rather than crop the page.
    private func boundedPNG(_ image: NSImage) throws -> (Data, NSSize) {
        guard let tiff = image.tiffRepresentation, var bitmap = NSBitmapImageRep(data: tiff) else {
            throw WorkspaceToolError.invalid("The preview image could not be encoded.")
        }
        while true {
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= 600_000 {
                return (png, NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            }
            guard bitmap.pixelsWide > 240 else { throw WorkspaceToolError.invalid("The preview image exceeds the response budget.") }
            let width = max(240, bitmap.pixelsWide * 2 / 3)
            let height = max(1, bitmap.pixelsHigh * width / bitmap.pixelsWide)
            guard let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: resized) else {
                throw WorkspaceToolError.invalid("The preview image could not be resized.")
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            bitmap = resized
        }
    }
}
