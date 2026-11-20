import AppKit
import WebKit
import WovenProtocol

/// Carries out the Woven MCP's `preview_html`: renders HTML the way the chat
/// shows a published visual reply (the same wrapper, sandbox, theme variables and
/// nonpersistent storage) in a web view that no window ever holds, waits for
/// it to load and settle, and captures it. Each preview has its own.
@MainActor final class VisualReplyPreview {
    static let loadLimit = Duration.seconds(15)
    /// The tallest part of a visual reply the screenshot covers.
    static let capturedHeightLimit = 2000

    private let coordinator = ConversationHTMLWebCoordinator()
    private var height: CGFloat = 80
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<Bool, Never>?

    func run(_ arguments: JSONValue) async -> ToolResult {
        guard let html = arguments["html"]?.string, let width = arguments["width"]?.int, (240...1600).contains(width),
              let appearance = arguments["appearance"]?.string, ["light", "dark"].contains(appearance) else {
            return .error("Give the HTML, a width from 240 to 1600 and an appearance of light or dark.")
        }
        let theme: WovenTheme = appearance == "dark" ? .dark : .green
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        defer { coordinator.stop(view) }
        coordinator.onHeight = { [weak self] in self?.height = $0 }
        coordinator.onReady = { [weak self] in self?.loaded(true) }
        coordinator.onFailure = { [weak self] in self?.failure = $0; self?.loaded(false) }

        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.loadLimit)
            self?.loaded(false)
        }
        let finished = await withCheckedContinuation { continuation in
            waiter = continuation
            coordinator.apply(html: html, theme: ConversationHTMLTheme.value(theme), to: view)
        }
        timer.cancel()
        if let failure { return .error("The visual reply could not be shown: \(failure.localizedDescription)") }
        await settle()

        let captured = min(Self.capturedHeightLimit, max(80, Int(height.rounded(.up))))
        view.frame.size.height = CGFloat(captured)
        try? await Task.sleep(for: .milliseconds(100))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.snapshotWidth = NSNumber(value: width)
        guard let image = try? await view.takeSnapshot(configuration: configuration) else {
            return .error("The visual reply could not be captured.")
        }

        var metadata: [String: JSONValue] = [
            "width": .integer(Int64(width)), "contentHeight": .integer(Int64(height.rounded(.up))),
            "capturedHeight": .integer(Int64(captured)),
            "consoleMessages": .array(coordinator.consoleMessages.map { message in
                .object(message.mapValues(JSONValue.string))
            })
        ]
        if !finished { metadata["loaded"] = .bool(false) }
        let reserve = (try? JSONEncoder().encode(JSONValue.object(metadata)).count) ?? 0
        // The image's base64 and the measurements fit the UI tools' result limit,
        // with room for what the server adds.
        let budget = (WovenAutomationHost.maximumResultBytes - reserve - 16_384) / 4 * 3
        guard let png = Self.png(image, width: width, height: captured,
                                 background: NSColor(theme.palette.workspace), limit: budget) else {
            return .error("The preview image does not fit in a tool result.")
        }
        metadata["screenshotWidth"] = .integer(Int64(png.width))
        metadata["screenshotHeight"] = .integer(Int64(png.height))
        let text = (try? JSONEncoder().encode(JSONValue.object(metadata))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ToolResult(content: [.text(text), .image(data: png.data.base64EncodedString(), mimeType: "image/png")])
    }

    private func loaded(_ ready: Bool) {
        let waiting = waiter
        waiter = nil
        waiting?.resume(returning: ready)
    }

    /// Waits until its height has held still for a moment, or a second.
    private func settle() async {
        var last = height, still = 0
        for _ in 0..<10 where still < 2 {
            try? await Task.sleep(for: .milliseconds(100))
            still = height == last ? still + 1 : 0
            last = height
        }
    }

    /// The capture over the chat's background, one pixel per CSS pixel, made
    /// smaller while its PNG is over `limit`; the area captured stays whole.
    private static func png(_ image: NSImage, width: Int, height: Int, background: NSColor,
                            limit: Int) -> (data: Data, width: Int, height: Int)? {
        var scale = 1.0
        while true {
            let pixelsWide = max(1, Int(Double(width) * scale)), pixelsHigh = max(1, Int(Double(height) * scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            let bounds = NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            background.setFill()
            bounds.fill()
            image.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            if let data = bitmap.representation(using: .png, properties: [:]), data.count <= limit {
                return (data, pixelsWide, pixelsHigh)
            }
            guard pixelsWide > 120 else { return nil }
            scale *= 2.0 / 3.0
        }
    }
}
