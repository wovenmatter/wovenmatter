import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAutomation

struct WovenComputerAutomationTests {
  @MainActor @Test func admissionFailsBeforeAnyDesktopOperation() async throws {
    let computer = WovenComputerAutomation()
    for action in ["apps", "launch", "screenshot", "click", "type", "press", "scroll"] {
      await #expect(throws: CancellationError.self) {
        try await computer.execute(.object(["action": .string(action)]), callerID: "fixture", admit: { throw CancellationError() })
      }
    }
  }

  @MainActor @Test func exactTargetsAndBackgroundDefaultsReachCuaWithoutCallerAuthority() throws {
    let target: [String: GatewayJSONValue] = ["action": .string("click"), "pid": .number(7), "windowID": .number(9), "elementToken": .string("s00000001:2")]
    let call = try WovenComputerAutomation.invocation(target)
    #expect(call.tool == "click")
    #expect(call.arguments["target"] == .object(["kind": .string("window"), "pid": .number(7), "window_id": .number(9)]))
    #expect(call.arguments["delivery_mode"] == .string("background"))
    #expect(call.arguments["element_token"] == target["elementToken"])
    for forbidden in ["session", "socket", "screenshot_out_file", "prompt", "callerID", "recording", "endpoint"] {
      var forged = target; forged[forbidden] = .string("forged")
      #expect(throws: WorkspaceToolError.self) { try WovenComputerAutomation.invocation(forged) }
    }
    #expect(throws: WorkspaceToolError.self) { try WovenComputerAutomation.invocation(["action": .string("click"), "scope": .string("desktop"), "x": .number(1), "y": .number(2), "captureID": .string("capture")]) }
    var mixed = target; mixed["x"] = .number(1)
    #expect(throws: WorkspaceToolError.self) { try WovenComputerAutomation.invocation(mixed) }
    var missingCapture = target; missingCapture.removeValue(forKey: "elementToken"); missingCapture["x"] = .number(1); missingCapture["y"] = .number(2)
    #expect(throws: WorkspaceToolError.self) { try WovenComputerAutomation.invocation(missingCapture) }
    var press = target; press["action"] = .string("press"); press["key"] = .string("cmd,shift,t")
    let hotkey = try WovenComputerAutomation.invocation(press)
    #expect(hotkey.tool == "hotkey" && hotkey.arguments["keys"] == .array([.string("cmd"), .string("shift"), .string("t")]))
  }

  @MainActor @Test func permissionAndRevocationFailuresNeverDispatchOrReturnCapturedContent() async throws {
    var calls = 0
    let refused = WovenComputerAutomation(executable: URL(fileURLWithPath: "/unused"), permissionCheck: { false }, driverCall: { _, _, _, _ in
      calls += 1; return .object(["content": .array([])])
    })
    await #expect(throws: WorkspaceToolError.self) { try await refused.execute(.object(["action": .string("apps")]), callerID: "one", admit: {}) }
    #expect(calls == 0)
    var authorized = true
    let revoked = WovenComputerAutomation(executable: URL(fileURLWithPath: "/unused"), permissionCheck: { true }, driverCall: { tool, args, caller, _ in
      #expect(tool == "list_apps" && args.isEmpty && caller == "one")
      calls += 1; authorized = false
      return .object(["content": .array([.object(["type": .string("text"), "text": .string("private result")])])])
    })
    await #expect(throws: WorkspaceToolError.self) {
      try await revoked.execute(.object(["action": .string("apps")]), callerID: "one", admit: {
        if !authorized { throw WorkspaceToolError.disabled(.computer) }
      })
    }
    #expect(calls == 1)
  }

  @MainActor @Test func driverRefusalsBecomeMcpErrorsAndImagesKeepCoordinateDimensions() async throws {
    let rejected = WovenComputerAutomation(executable: URL(fileURLWithPath: "/unused"), permissionCheck: { true }, driverCall: { _, _, _, _ in
      .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("stale_element_token")])])])
    })
    await #expect(throws: WorkspaceToolError.invalid("stale_element_token")) { try await rejected.execute(.object(["action": .string("apps")]), callerID: "one", admit: {}) }
    let png = try computerFixturePNG()
    let images = WovenComputerAutomation(executable: URL(fileURLWithPath: "/unused"), permissionCheck: { true }, driverCall: { _, _, _, _ in
      .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])]), "structuredContent": .object(["capture_id": .string("c1")])])
    })
    let result = try await images.execute(.object(["action": .string("screenshot")]), callerID: "one", admit: {})
    let image = try #require(result.objectValue?["content"]?.arrayValue?.first?.objectValue)
    #expect(image["mimeType"] == .string("image/jpeg"))
    let encodedImage = try #require(image["data"]?.stringValue)
    let imageData = try #require(Data(base64Encoded: encodedImage))
    let decoded = try computerFixtureImageSize(imageData)
    #expect(decoded.0 == 32 && decoded.1 == 16)
    #expect(result.objectValue?["structuredContent"]?.objectValue?["capture_id"] == .string("c1"))
  }

  @MainActor @Test(.timeLimit(.minutes(1))) func privateMcpSessionsReuseOnlyTheirCallerAndCancellationDoesNotReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "woven-cua-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appending(path: "driver")
    try #"""
    #!/usr/bin/python3
    import json,os,socket,sys,time
    if sys.argv[1]=='serve':
        sock=socket.socket(socket.AF_UNIX);sock.bind(sys.argv[sys.argv.index('--socket')+1]);sock.listen()
        sys.stdin.buffer.read();sys.exit(0)
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        if m['method']=='initialize': result={'protocolVersion':'2025-03-26','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
        else:
            name=m['params']['name']
            if name=='hang': time.sleep(30)
            if name=='crash': os._exit(9)
            result={'content':[{'type':'text','text':'héllo'}],'structuredContent':{'pid':os.getpid(),'tool':name}}
        data=(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result},ensure_ascii=False)+'\n').encode()
        cut=data.index('é'.encode())+1 if 'é'.encode() in data else 1
        sys.stdout.buffer.write(data[:cut]);sys.stdout.buffer.flush()
        sys.stdout.buffer.write(data[cut:]);sys.stdout.buffer.flush()
    """#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let runtime = WovenCuaRuntime(executable: script, bundleID: "wovenmatter.fixture")
    defer { runtime.stop() }
    let first = try await runtime.call("list_apps", arguments: [:], callerID: "one", admit: {})
    let second = try await runtime.call("list_apps", arguments: [:], callerID: "one", admit: {})
    let other = try await runtime.call("list_apps", arguments: [:], callerID: "two", admit: {})
    #expect(first == second)
    #expect(first.objectValue?["structuredContent"]?.objectValue?["pid"] != other.objectValue?["structuredContent"]?.objectValue?["pid"])
    #expect(first.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"] == .string("héllo"))
    let task = Task { try await runtime.call("hang", arguments: [:], callerID: "one", admit: {}) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    let replacement = try await runtime.call("list_apps", arguments: [:], callerID: "one", admit: {})
    #expect(first.objectValue?["structuredContent"]?.objectValue?["pid"] != replacement.objectValue?["structuredContent"]?.objectValue?["pid"])
    #expect(try await runtime.call("list_apps", arguments: [:], callerID: "two", admit: {}) == other)
    await #expect(throws: (any Error).self) { try await runtime.call("crash", arguments: [:], callerID: "one", admit: {}) }
    let recovered = try await runtime.call("list_apps", arguments: [:], callerID: "one", admit: {})
    #expect(recovered.objectValue?["structuredContent"]?.objectValue?["pid"] != replacement.objectValue?["structuredContent"]?.objectValue?["pid"])
  }

  @Test func computerUseRemainsOffForNewSettingsAndChats() {
    #expect(!WorkspaceToolSettings().enabledByDefault.contains(.computer))
    #expect(!WorkspaceSessionTools().enabled.contains(.computer))
  }
}
