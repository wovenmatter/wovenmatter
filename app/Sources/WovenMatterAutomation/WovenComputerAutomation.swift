import AppKit
import ApplicationServices
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import WovenMatterCore
import WovenMatterClient

/// User-approved broad desktop control. The app-owned host checks the current
/// Computer Use capability on every invocation and immediately before input.
/// Services are embedded in the signed GUI app, never a generic Node runtime.
@MainActor
public final class WovenComputerAutomation {
    private let logging: LoggingService = {
        let service = LoggingService(); service.minimumLogLevel = .critical; return service
    }()
    private lazy var input = UIAutomationService(loggingService: logging)
    private lazy var capture = ScreenCaptureService(loggingService: logging, feedbackClient: NoopAutomationFeedbackClient())
    private struct Frame {
        let id: String
        let bounds: CGRect
        let imageSize: CGSize
        let topology: [CGRect]
        let created: Date
        let foregroundPID: pid_t?
    }
    private var frames: [String: Frame] = [:]
    public init() {}
    public static var permissions: GatewayJSONValue {
        .object(["screenRecording": .bool(CGPreflightScreenCaptureAccess()), "accessibility": .bool(AXIsProcessTrusted())])
    }
    public func revoke(callerID: String) { frames[callerID] = nil }
    public func revokeAll() { frames.removeAll() }

    public func execute(_ value: GatewayJSONValue, callerID: String,
                        admit: @MainActor () async throws -> Void) async throws -> GatewayJSONValue {
        guard let args = value.objectValue, let action = args["action"]?.stringValue else { throw WorkspaceToolError.invalid("Provide a computer action.") }
        let keys: Set<String> = ["action", "frameId", "x", "y", "button", "text", "key", "direction", "amount", "screen", "app"]
        guard Set(args.keys).isSubset(of: keys) else { throw WorkspaceToolError.invalid("Unknown computer parameter.") }
        try await admit(); try Task.checkCancellation()
        switch action {
        case "status": return Self.text(Self.permissions)
        case "apps": return Self.text(.array(NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return .object(["app": .string(id), "name": .string(app.localizedName ?? id)])
        }))
        case "launch":
            guard let id = args["app"]?.stringValue, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { throw WorkspaceToolError.invalid("Choose an app bundle ID from apps.") }
            revokeAll()
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return Self.text(.object(["launched": .string(id)]))
        case "screenshot":
            guard CGPreflightScreenCaptureAccess() else { throw WorkspaceToolError.invalid("Grant Woven Matter Screen Recording access in macOS System Settings, then reopen the app if macOS requests it.") }
            guard let screen = (args["screen"] ?? .number(0)).intValue else { throw WorkspaceToolError.invalid("Screen index must be an integer.") }
            guard screen >= 0, screen < NSScreen.screens.count else { throw WorkspaceToolError.invalid("Invalid screen index.") }
            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let result = try await capture.captureScreen(displayIndex: screen, scale: .logical1x)
            try await admit(); try Task.checkCancellation()
            guard let bounds = result.metadata.displayInfo?.bounds, let source = NSBitmapImageRep(data: result.imageData) else { throw WorkspaceToolError.invalid("Screen capture has no verified display geometry.") }
            let factor = min(1, 1600 / Double(source.pixelsWide))
            let width = max(1, Int(Double(source.pixelsWide) * factor)), height = max(1, Int(Double(source.pixelsHigh) * factor))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw WorkspaceToolError.invalid("Screenshot could not be resized.") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSImage(data: result.imageData)?.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55]), jpeg.count < 650000 else { throw WorkspaceToolError.invalid("Screenshot exceeds the image limit.") }
            let id = UUID().uuidString.lowercased()
            guard foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw WorkspaceToolError.invalid("The foreground app changed while capturing. Capture a fresh screenshot.") }
            frames[callerID] = .init(id: id, bounds: bounds, imageSize: CGSize(width: width, height: height), topology: NSScreen.screens.map(\.frame), created: Date(), foregroundPID: foregroundPID)
            return .object(["content": .array([
                .object(["type": .string("text"), "text": .string("frameId: \(id); coordinates: screenshot pixels; size: \(width)x\(height). Capture again after input.")]),
                .object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(jpeg.base64EncodedString())])])])
        case "click", "type", "press", "scroll":
            guard AXIsProcessTrusted() else { throw WorkspaceToolError.invalid("Grant Woven Matter Accessibility access in macOS System Settings.") }
            guard let frame = frames[callerID], args["frameId"]?.stringValue == frame.id,
                  Date().timeIntervalSince(frame.created) < 30, NSScreen.screens.map(\.frame) == frame.topology,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.foregroundPID else { throw WorkspaceToolError.invalid("Capture a fresh screenshot for this session before input.") }
            revokeAll()
            try await admit(); try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.foregroundPID else { throw WorkspaceToolError.invalid("The foreground app changed before input. Capture a fresh screenshot.") }
            if action == "click" {
                guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue,
                      x.isFinite, y.isFinite, x >= 0, y >= 0, x < frame.imageSize.width, y < frame.imageSize.height,
                      let button = ClickType(rawValue: args["button"]?.stringValue ?? "single") else { throw WorkspaceToolError.invalid("Use screenshot pixel coordinates and a valid button.") }
                try await input.click(target: .coordinates(CGPoint(x: frame.bounds.minX + x * frame.bounds.width / frame.imageSize.width,
                    y: frame.bounds.minY + y * frame.bounds.height / frame.imageSize.height)), clickType: button, snapshotId: nil)
            } else if action == "type" {
                guard let text = args["text"]?.stringValue, text.utf8.count <= 65536 else { throw WorkspaceToolError.invalid("Provide text within 64 KiB.") }
                // Peekaboo's zero-delay character loop does not yield. Bound each
                // dispatch so Stop/revocation can run between text batches.
                var cursor = text.startIndex
                while cursor < text.endIndex {
                    try await admit(); try Task.checkCancellation()
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.foregroundPID else { throw WorkspaceToolError.invalid("The foreground app changed during typing. Inspect a new screenshot before continuing.") }
                    let end = text.index(cursor, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
                    try await input.type(text: String(text[cursor..<end]), target: nil, clearExisting: false, typingDelay: 0, snapshotId: nil)
                    cursor = end
                    await Task.yield()
                }
            } else if action == "press" {
                guard let key = args["key"]?.stringValue, key.count <= 100 else { throw WorkspaceToolError.invalid("Provide a key combination.") }
                try await input.hotkey(keys: key, holdDuration: 50)
            } else {
                guard let direction = ScrollDirection(rawValue: args["direction"]?.stringValue ?? "down") else { throw WorkspaceToolError.invalid("Invalid scroll direction.") }
                guard let amount = (args["amount"] ?? .number(5)).intValue else { throw WorkspaceToolError.invalid("Scroll amount must be an integer.") }
                guard (1...50).contains(amount) else { throw WorkspaceToolError.invalid("Scroll amount must be 1...50.") }
                for _ in 0..<amount {
                    try await admit(); try Task.checkCancellation()
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.foregroundPID else { throw WorkspaceToolError.invalid("The foreground app changed during scrolling. Capture a fresh screenshot.") }
                    try await input.scroll(.init(direction: direction, amount: 1, foreground: true))
                    await Task.yield()
                }
            }
            return Self.text(.object(["dispatched": .bool(true), "verification": .string("Capture a new screenshot to verify the effect.")]))
        default: throw WorkspaceToolError.invalid("Unknown computer action.")
        }
    }
    private static func text(_ value: GatewayJSONValue) -> GatewayJSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "")])])])
    }
}
