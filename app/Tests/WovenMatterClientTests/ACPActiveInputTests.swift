import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct ACPActiveInputTests {
    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .cursor, .grokBuild])
    func activeInputStreamsWithoutCancellingOrStartingAnotherSession(kind: AgentRuntimeKind) async throws {
        let f = try ActiveInputFixture(mode: "ordinary")
        defer { f.remove() }
        let client = try f.client(kind)
        _ = try await client.initializeSession(workingDirectory: f.root, existingSessionID: nil, title: nil)
        let events = ActiveInputEvents()
        let prompt = Task { try await client.prompt("start", onEvent: { await events.record($0) }) }
        try await f.waitForPrompt()
        for text in ["first", "second", "finish"] {
            let receipt = try await client.beginActiveInput(text)
            if kind != .cursor { #expect(try await receipt.completion.value == nil) }
        }
        #expect(try await prompt.value == .endTurn)
        await client.shutdown()
        #expect(await events.text() == "beforefirstsecondfinish")
        let requests = try f.requests()
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 1)
        #expect(!requests.contains { $0["method"] as? String == "session/cancel" })
    }

    @Test(arguments: ["detached", "detached-fast", "detached-late-active", "detached-old-idle", "command-only", "fallback"])
    func aSteerRacingCompletionRetainsHandlersAndWaitsForItsOwnOutput(mode: String) async throws {
        let f = try ActiveInputFixture(mode: mode)
        defer { f.remove() }
        let client = try f.client(mode == "fallback" ? .claudeCode : .codex)
        _ = try await client.initializeSession(workingDirectory: f.root, existingSessionID: nil, title: nil)
        let events = ActiveInputEvents()
        let prompt = Task { try await client.prompt("start", onEvent: { await events.record($0) }) }
        try await f.waitForPrompt()
        let receipt = try await client.beginActiveInput(mode == "command-only" ? "/status" : "continue")
        #expect(try await prompt.value == .endTurn)
        #expect(try await receipt.completion.value == .endTurn)
        #expect(await events.text() == "beforecontinued")
        await client.shutdown()
    }

    @Test func stopDuringAdmissionDoesNotStartTheFallbackPrompt() async throws {
        let f = try ActiveInputFixture(mode: "cancel-fallback")
        defer { f.remove() }
        let client = try f.client(.claudeCode)
        _ = try await client.initializeSession(workingDirectory: f.root, existingSessionID: nil, title: nil)
        let prompt = Task { try await client.prompt("start") }
        try await f.waitForPrompt()
        let steering = Task { try await client.beginActiveInput("correction") }
        for _ in 0..<500 {
            if try f.requests().contains(where: { $0["method"] as? String == "_session/steering" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await client.cancel()
        await #expect(throws: CancellationError.self) { try await steering.value }
        #expect(try await prompt.value == .cancelled)
        #expect(try f.requests().filter { $0["method"] as? String == "session/prompt" }.count == 1)
        await client.shutdown()
    }

    @Test func commandOnlyClassificationLeavesNativeWorkUnderObservation() {
        for text in ["/status", "/STATUS", "/ status", "/plan", "/rename title", "/skills", "/mcp", "/goal pause", "/goal clear", "/review-branch"] {
            #expect(LocalACPClient.codexCommandCompletesWithoutTurn(text))
        }
        for text in ["ordinary", "/compact", "/review", "/review-branch main", "/goal resume", "/goal implement this", "/skill:review"] {
            #expect(!LocalACPClient.codexCommandCompletesWithoutTurn(text))
        }
    }

    @Test func unsupportedAndRejectedSteersThrowAtAdmission() async throws {
        for mode in ["unsupported", "rejected", "uncertain"] {
            let f = try ActiveInputFixture(mode: mode)
            defer { f.remove() }
            let client = try f.client(.codex)
            _ = try await client.initializeSession(workingDirectory: f.root, existingSessionID: nil, title: nil)
            let prompt = Task { try await client.prompt("start") }
            try await f.waitForPrompt()
            do { _ = try await client.beginActiveInput("reject"); Issue.record("Expected an admission error") }
            catch let error as LocalACPClientError {
                if case .deliveryUncertain = error { #expect(mode == "uncertain") }
                else { #expect(mode != "uncertain") }
            }
            try await client.cancel()
            _ = try await prompt.value
            await client.shutdown()
        }
    }
}

private actor ActiveInputEvents {
    var chunks: [String] = []
    func record(_ event: LocalACPEvent) { if case .assistantChunk(let text) = event { chunks.append(text) } }
    func text() -> String { chunks.joined() }
}

private struct ActiveInputFixture {
    let root: URL
    let executable: URL
    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "active-input-\(UUID())")
        executable = root.appending(path: "adapter.py")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,os,time
        os.chdir(os.path.dirname(__file__))
        mode = "MODE"
        original = None
        prompts = []
        steering = None
        def send(v): print(json.dumps(dict(jsonrpc="2.0", **v)), flush=True)
        def result(i, v): send(dict(id=i, result=v))
        def update(v): send(dict(method="session/update", params=dict(sessionId="parent", update=v)))
        def text(s): update(dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text=s)))
        def status(s): update(dict(sessionUpdate="session_info_update", _meta=dict(codex=dict(threadStatus=dict(type=s)))))
        for line in sys.stdin:
            r=json.loads(line)
            with open('requests.jsonl','a') as log: log.write(line)
            method=r.get('method'); i=r.get('id'); p=r.get('params',{})
            value=''.join(b.get('text','') for b in p.get('prompt',[])) or p.get('text','')
            if method=='initialize': result(i,dict(protocolVersion=2,_meta=dict(steering=dict(supported=mode!='unsupported'))))
            elif method=='session/new': result(i,dict(sessionId='parent'))
            elif method in ['authenticate','cursor/list_available_models']: result(i,{})
            elif method=='session/cancel':
                for pid in prompts: result(pid,dict(stopReason='cancelled'))
                prompts=[]
                if steering is not None: result(steering,dict(outcome='promptRequired'))
            elif method=='session/prompt' and original is None:
                original=i; prompts.append(i); text('before')
                if mode=='detached-old-idle': status('active'); status('idle')
                open('ready','w').close()
            elif method in ['_session/steering','_x.ai/interject','session/prompt']:
                if mode in ['rejected','uncertain']:
                    send(dict(id=i,error=dict(code=-32602,message='Steer rejected',data=dict(deliveryUncertain=mode=='uncertain')))); continue
                if mode=='cancel-fallback':
                    if method=='_session/steering': steering=i
                    else: result(i,dict(stopReason='end_turn'))
                elif mode=='command-only':
                    result(original,dict(stopReason='end_turn')); text('continued')
                    assert p['_meta']['wovenCommandOnly'] == True
                    result(i,dict(outcome='startedNewTurn'))
                elif mode.startswith('detached'):
                    if mode!='detached-old-idle': status('active')
                    result(original,dict(stopReason='end_turn')); status('idle')
                    if mode!='detached-late-active': status('active')
                    if mode=='detached-fast': text('continued'); status('idle')
                    result(i,dict(outcome='startedNewTurn'))
                    if mode=='detached-late-active': time.sleep(.03); status('active')
                    if mode!='detached-fast': time.sleep(.03); text('continued'); status('idle')
                elif mode=='fallback':
                    if method=='_session/steering':
                        result(original,dict(stopReason='end_turn')); result(i,dict(outcome='promptRequired'))
                    else: text('continued'); result(i,dict(stopReason='end_turn'))
                else:
                    if method=='session/prompt': prompts.append(i)
                    else: result(i,dict(outcome='injected'))
                    text(value)
                    if value=='finish':
                        for pid in prompts: result(pid,dict(stopReason='end_turn'))
                        prompts=[]
        """#.replacingOccurrences(of: "MODE", with: mode)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func client(_ kind: AgentRuntimeKind) throws -> LocalACPClient {
        try .start(launch: .init(runtimeKind: kind, executableURL: executable, arguments: []), workingDirectory: root)
    }
    func waitForPrompt() async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: root.appending(path: "ready").path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalACPClientError.processExited
    }
    func requests() throws -> [[String: Any]] {
        try String(contentsOf: root.appending(path: "requests.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
