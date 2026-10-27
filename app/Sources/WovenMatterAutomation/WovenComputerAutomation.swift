import AppKit
import ApplicationServices
import Foundation
import WovenMatterCore
import WovenMatterClient

/// All desktop operations use Cua. Woven retains caller identity, admission,
/// cancellation and inline-image limits; agents never receive the driver socket.
@MainActor
public final class WovenComputerAutomation {
    typealias DriverCall = @MainActor (String, [String: GatewayJSONValue], String,
        @MainActor () async throws -> Void) async throws -> GatewayJSONValue
    private let runtime: WovenCuaRuntime
    private let driverCall: DriverCall?
    private let permissionCheck: @MainActor () -> Bool
    public convenience init() {
        self.init(executable: Bundle.main.resourceURL?.appending(path: "Cua/cua-driver") ?? URL(fileURLWithPath: "/missing-cua"))
    }
    init(executable: URL, permissionCheck: @escaping @MainActor () -> Bool = {
        CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()
    }, driverCall: DriverCall? = nil) {
        runtime = WovenCuaRuntime(executable: executable, bundleID: Bundle.main.bundleIdentifier ?? "wovenmatter.desktop")
        self.permissionCheck = permissionCheck; self.driverCall = driverCall
    }
    public static var permissions: GatewayJSONValue {
        .object(["engine": .string("cua"), "screenRecording": .bool(CGPreflightScreenCaptureAccess()), "accessibility": .bool(AXIsProcessTrusted())])
    }
    public func revoke(callerID: String) { runtime.revoke(callerID: callerID) }
    public func revokeAll() { runtime.stop() }
    public func execute(_ value: GatewayJSONValue, callerID: String,
                        admit: @MainActor () async throws -> Void) async throws -> GatewayJSONValue {
        try await admit(); try Task.checkCancellation()
        guard let args = value.objectValue, let action = args["action"]?.stringValue else { throw Self.invalid("Provide a computer action.") }
        if action == "status" {
            guard args.count == 1 else { throw Self.invalid("Status accepts only action.") }
            return .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: try JSONEncoder().encode(Self.permissions), as: UTF8.self))])])])
        }
        let call = try Self.invocation(args)
        guard permissionCheck() else { throw Self.invalid("Grant Woven Matter Screen Recording and Accessibility in macOS System Settings, then reopen the app. Agents cannot grant these permissions.") }
        try await admit(); try Task.checkCancellation()
        let result: GatewayJSONValue
        if let driverCall { result = try await driverCall(call.tool, call.arguments, callerID, admit) }
        else { result = try await runtime.call(call.tool, arguments: call.arguments, callerID: callerID, admit: admit) }
        try await admit(); try Task.checkCancellation()
        if result.objectValue?["isError"]?.boolValue == true {
            let text = result.objectValue?["content"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            throw Self.invalid(String((text ?? "Cua refused the action. Inspect fresh state.").prefix(32_768)))
        }
        return try Self.inlineImages(result)
    }
    struct Invocation: Equatable { let tool: String; let arguments: [String: GatewayJSONValue] }
    static func invocation(_ args: [String: GatewayJSONValue]) throws -> Invocation {
        let action = args["action"]?.stringValue ?? ""
        var allowed: Set<String> = ["action"], input: [String: GatewayJSONValue] = [:]
        let tool: String
        switch action {
        case "apps": tool = "list_apps"
        case "windows":
            tool = "list_windows"; allowed.insert("pid")
            if let pid = args["pid"] { input["pid"] = try integer(pid, "pid", 1...Int(UInt32.max)) }
        case "launch":
            tool = "launch_app"; allowed.insert("app"); input["bundle_id"] = try string(args["app"], "app", 256)
        case "snapshot":
            tool = "get_window_state"; allowed.formUnion(["pid", "windowID", "query", "maxElements", "maxDepth", "includeScreenshot", "since", "treeFormat"])
            input["pid"] = try integer(args["pid"], "pid", 1...Int(UInt32.max))
            input["window_id"] = try integer(args["windowID"], "windowID", 1...Int(UInt32.max))
            input["max_dimension"] = .number(1280); input["max_image_dimension"] = .number(1280)
            input["max_elements"] = try integer(args["maxElements"] ?? .number(250), "maxElements", 1...1000)
            input["max_depth"] = try integer(args["maxDepth"] ?? .number(25), "maxDepth", 1...50)
            input["timeout_ms"] = .number(3000)
            for key in ["query", "since"] { if let value = args[key] { input[key] = try string(value, key, 1024) } }
            if let format = args["treeFormat"] {
                guard ["markdown", "elements", "both"].contains(format.stringValue ?? "") else { throw invalid("Unknown treeFormat.") }
                input["tree_format"] = format
            }
            if let value = args["includeScreenshot"] {
                guard value.boolValue != nil else { throw invalid("includeScreenshot must be boolean.") }
                input["include_screenshot"] = value
            }
        case "screenshot": tool = "get_desktop_state"; input["max_image_dimension"] = .number(1280)
        case "click", "type", "press", "scroll", "drag", "move":
            allowed.formUnion(["pid", "windowID", "scope", "deliveryMode"])
            let scope = args["scope"]?.stringValue ?? "window", delivery = args["deliveryMode"]?.stringValue ?? "background"
            guard ["window", "desktop"].contains(scope), ["background", "foreground"].contains(delivery),
                  scope != "desktop" || delivery == "foreground" else { throw invalid("Use background for windows; desktop input requires explicit deliveryMode foreground.") }
            if scope == "window" {
                input["target"] = .object(["kind": .string("window"), "pid": try integer(args["pid"], "pid", 1...Int(UInt32.max)),
                    "window_id": try integer(args["windowID"], "windowID", 1...Int(UInt32.max))])
            } else {
                guard args["pid"] == nil, args["windowID"] == nil else { throw invalid("Desktop input cannot name a window.") }
                input["target"] = .object(["kind": .string("desktop"), "display_id": .string("primary")])
            }
            input["delivery_mode"] = .string(delivery)
            if ["click", "type", "press"].contains(action) {
                allowed.formUnion(["x", "y", "elementToken"])
                if action == "click" { allowed.insert("captureID") }
                if let token = args["elementToken"] {
                    guard scope == "window", args["x"] == nil, args["y"] == nil, args["captureID"] == nil else { throw invalid("Use either an elementToken or screenshot coordinates.") }
                    input["element_token"] = try string(token, "elementToken", 128)
                } else if args["x"] != nil || args["y"] != nil || action == "click" {
                    input["x"] = try coordinate(args["x"], "x"); input["y"] = try coordinate(args["y"], "y")
                    if action == "click" { input["capture_id"] = try string(args["captureID"], "captureID", 256) }
                }
            }
            switch action {
            case "click":
                tool = "click"; allowed.formUnion(["button", "clickCount"])
                let button = args["button"]?.stringValue ?? "left"
                guard ["left", "right", "middle"].contains(button) else { throw invalid("Unknown mouse button.") }
                input["button"] = .string(button); input["count"] = try integer(args["clickCount"] ?? .number(1), "clickCount", 1...3)
            case "type": tool = "type_text"; allowed.insert("text"); input["text"] = try string(args["text"], "text", 4096)
            case "press":
                allowed.insert("key")
                let key = try string(args["key"], "key", 100).stringValue!
                let keys = key.split(whereSeparator: { $0 == "+" || $0 == "," }).map(String.init)
                if keys.count > 1 { tool = "hotkey"; input["keys"] = .array(keys.map(GatewayJSONValue.string)) }
                else { tool = "press_key"; input["key"] = .string(key) }
            case "scroll":
                tool = "scroll"; allowed.formUnion(["x", "y", "direction", "amount"])
                input["x"] = try coordinate(args["x"], "x"); input["y"] = try coordinate(args["y"], "y")
                let direction = args["direction"]?.stringValue ?? "down"
                guard ["up", "down", "left", "right"].contains(direction) else { throw invalid("Invalid scroll direction.") }
                input["direction"] = .string(direction); input["amount"] = try integer(args["amount"] ?? .number(5), "amount", 1...50)
            case "drag":
                tool = "drag"; allowed.formUnion(["x", "y", "toX", "toY"])
                for (key, native) in [("x", "from_x"), ("y", "from_y"), ("toX", "to_x"), ("toY", "to_y")] { input[native] = try coordinate(args[key], key) }
            default:
                tool = "move_cursor"; allowed.formUnion(["x", "y"])
                input["x"] = try coordinate(args["x"], "x"); input["y"] = try coordinate(args["y"], "y")
            }
        default: throw invalid("Unknown computer action.")
        }
        guard Set(args.keys).isSubset(of: allowed) else { throw invalid("Unknown parameter for computer \(action).") }
        return .init(tool: tool, arguments: input)
    }
    private static func invalid(_ message: String) -> WorkspaceToolError { .invalid(message) }
    private static func integer(_ value: GatewayJSONValue?, _ name: String, _ range: ClosedRange<Int>) throws -> GatewayJSONValue {
        guard let n = value?.intValue, range.contains(n) else { throw invalid("\(name) must be an integer in \(range).") }; return .number(Double(n))
    }
    private static func coordinate(_ value: GatewayJSONValue?, _ name: String) throws -> GatewayJSONValue {
        guard let n = value?.doubleValue, n.isFinite, (0...100_000).contains(n) else { throw invalid("Provide a nonnegative screenshot pixel coordinate for \(name).") }; return .number(n)
    }
    private static func string(_ value: GatewayJSONValue?, _ name: String, _ maximum: Int) throws -> GatewayJSONValue {
        guard let s = value?.stringValue, !s.isEmpty, s.utf8.count <= maximum else { throw invalid("Provide \(name) within \(maximum) UTF-8 bytes.") }; return .string(s)
    }
    private static func inlineImages(_ result: GatewayJSONValue) throws -> GatewayJSONValue {
        guard var object = result.objectValue, let content = object["content"]?.arrayValue else { throw invalid("Invalid Cua tool result.") }
        object["content"] = .array(try content.map { block in
            guard var image = block.objectValue, image["type"] == .string("image") else { return block }
            // Preserve dimensions so Cua's screenshot-coordinate transform stays valid.
            guard let encoded = image["data"]?.stringValue, let data = Data(base64Encoded: encoded),
                  let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide <= 1280, bitmap.pixelsHigh <= 1280,
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55]), jpeg.count <= 650_000 else {
                throw invalid("Cua screenshot exceeds the inline image limit. Use a narrower window snapshot.")
            }
            image["data"] = .string(jpeg.base64EncodedString()); image["mimeType"] = .string("image/jpeg"); return .object(image)
        })
        return .object(object)
    }
}
