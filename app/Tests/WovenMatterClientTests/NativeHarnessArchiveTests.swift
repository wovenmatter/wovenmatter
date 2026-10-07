import Foundation
import CryptoKit
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct NativeHarnessArchiveTests {
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func oversizedLivePiEventKeepsStopControlAvailableWhileArchiveIsBlocked(shutdown: Bool) async throws {
        let gate = NativeArchiveGate()
        let fixture = PiPipeFixture(recorder: { direction, data in if direction == "native" { try await gate.record(data) } })
        let client = fixture.client
        let server = Task {
            defer { try? fixture.events.fileHandleForWriting.close() }
            let cursor = FixtureCommandReader(handle: fixture.commands.fileHandleForReading)
            while let bytes = try await cursor.next() {
                let request = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let type = try #require(request["type"] as? String)
                var data: [String: Any] = [:]
                if type == "get_state" { data = ["sessionId": "native-session", "sessionFile": "/fixture/store",
                    "isStreaming": false, "isCompacting": false, "pendingMessageCount": 0] }
                if type == "get_entries" { data = ["entries": []] }
                if type == "abort" { await gate.didAbort() }
                try fixture.emit(["type": "response", "id": request["id"]!, "command": type, "success": true, "data": data])
                if type == "prompt" {
                    try fixture.emit(["type": "agent_start"])
                    let block = Data(repeating: 120, count: 64 * 1_024)
                    for _ in 0..<(shutdown ? 3 : 1) {
                        try fixture.events.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"message_end\",\"message\":{\"content\":\"".utf8))
                        for _ in 0..<(shutdown ? 18 : 1_072) { try fixture.events.fileHandleForWriting.write(contentsOf: block) }
                        try fixture.events.fileHandleForWriting.write(contentsOf: Data("\",\"role\":\"assistant\",\"stopReason\":\"length\"},\"details\":{\"role\":\"user\",\"stopReason\":\"error\"}}\n".utf8))
                    }
                    await gate.framesEmitted()
                    try fixture.emit(["type": "agent_settled"])
                }
            }
        }
        _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp"), existingSessionID: "native-session", title: nil, systemPrompt: nil)
        await client.setRunID("woven-run")
        let turn = Task { try await client.prompt("fixture") }
        try await gate.waitFor(frames: false)
        if shutdown {
            // Three spooled frames exercise the bounded queue: two owned tasks
            // plus a reader waiting for archive backpressure when retired.
            try await gate.waitFor(frames: true)
            await client.shutdown()
            await #expect(throws: (any Error).self) { try await turn.value }
            #expect(await gate.cancelled)
            #expect(await gate.eventReferences == 0)
            try await server.value
            return
        }
        // A disk/SQLite archive wait cannot block replies to native Stop.
        await client.cancel()
        #expect(await gate.aborted)
        await gate.release()
        #expect(try await turn.value == .cancelled)
        #expect(await gate.eventReferences == 1)
        #expect(await gate.fragments > 250)
        await client.shutdown(); try await server.value
    }

    @Test func nativeMessageMetadataCannotBeOverwrittenBySiblingDetails() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"length\"},\"details\":{\"role\":\"user\",\"stopReason\":\"error\"}}".utf8).write(to: file)
        let metadata = try await PiNativeHistoryFrame.inspectObject(file)
        #expect(metadata.messageScalars["role"] == "assistant")
        #expect(metadata.messageScalars["stopReason"] == "length")
    }

    @Test(.timeLimit(.minutes(3)), arguments: ["hermes", "opencode"])
    func oversizedNativeRecordsRemainCompleteSearchableAndUseSanitizedOffsets(harness: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.json"), restored = directory.appendingPathComponent("archived.json")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        let endpoint = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
        let prefix = harness == "hermes" ? "{\"id\":\"native-session\",\"note\":\"\(endpoint)\",\"messages\":[{\"content\":\""
            : "{\"note\":\"\(endpoint)\",\"data\":[{\"text\":\""
        try output.write(contentsOf: Data(prefix.utf8))
        let block = Data(repeating: 120, count: 64 * 1_024)
        for _ in 0..<1_072 { try output.write(contentsOf: block) }
        // Native identities after the huge string must still be observed.
        let suffix = harness == "hermes" ? "\\nneedle\\u00e9\\ud83e\\uddf5\",\"role\":\"assistant\",\"id\":23}],\"compression_parent\":\"older\"}"
            : "\\nneedle\\u00e9\\ud83e\\uddf5\",\"type\":\"assistant\",\"id\":\"message-large\"}],\"cursor\":{\"next\":\"message-large\"}}"
        try output.write(contentsOf: Data(suffix.utf8)); try output.close()
        let count = try #require((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue)
        #expect(count > 64 * 1_024 * 1_024)
        let capture = try NativeDiskCapture(file: restored)
        let recorder: WorkspaceWireRecorder = { _, data in try await capture.append(data) }
        if harness == "hermes" {
            #expect(try await HermesSessionHistory.archiveFile(file, byteCount: count, sessionID: "native-session",
                identityHome: "/fixture/.hermes", recorder: recorder, afterMessageID: nil, runID: nil) == 23)
        } else {
            let page = try await OpenCodeNativeArchive.page(file, byteCount: count, path: "/api/session/native-session/message",
                sourceID: "opencode:fixture", recorder: recorder)
            #expect(page["data"].array.first?["id"].text == "message-large")
            #expect(page["data"].array.first?["type"].text == "assistant")
            #expect(page["data"].array.first?["text"].isNull == true)
            #expect(page["cursor"]["next"].text == "message-large")
        }
        try await capture.closeAndValidate()
        #expect(await capture.fidelity == "tool-endpoint-redacted")
        #expect(await capture.searchedEscapes)
        #expect(await capture.fragmentCount > 250)
        #expect(await capture.maximumPayloadBytes < 400_000)
        #expect(await capture.recordID == (harness == "hermes" ? "message:23" : "message:message-large"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func hermesFinalArchiveKeepsControlReaderLiveAndRetiresOnShutdown(shutdown: Bool) async throws {
        let gate = NativeArchiveGate(), transport = HermesTransportFixture(archiveGate: gate)
        var launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes, executableURL: URL(filePath: "/fixture/hermes"), arguments: [])
        launch.historyRecorder = { _, _ in }
        let client = HermesGatewayClient(launch: launch, transport: transport, home: "/fixture/.hermes")
        _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task { try await client.prompt(.init(text: "fixture"), onEvent: nil, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        let delivered = Task { await transport.complete() }
        try await gate.waitFor(frames: false)
        // Native reader's event callback returns while the archive is blocked.
        await delivered.value
        if shutdown {
            await client.shutdown()
            await #expect(throws: CancellationError.self) { try await turn.value }
            #expect(await gate.cancelled)
        } else {
            try await client.cancel()
            #expect(await transport.calls.filter { $0.0 == "session.interrupt" }.count == 1)
            await gate.release()
            #expect(try await turn.value == .cancelled)
            await client.shutdown()
        }
    }

    @Test func hermesStreamsExportMessagesAndExactRawChunksDeduplicateAcrossSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("export.json")
        let output = String(repeating: "tool 🧵 output with escaped quote \" and bracket ] ", count: 30_000)
        let bytes = Data(("{\"id\":\"native-session\",\"messages\":[{\"id\":7,\"role\":\"tool\",\"content\":"
            + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.fragmentsAllowed]), as: UTF8.self)
            + "},{\"id\":8,\"role\":\"assistant\",\"thinking\":\"exposed summary\",\"content\":[{\"type\":\"image\",\"url\":\"native://attachment\"}]}],\"compression_parent\":\"older-store\"}").utf8)
        try bytes.write(to: file)
        let capture = NativeBatchCapture()
        let recorder: WorkspaceWireRecorder = { _, data in try await capture.append(data) }
        let maximum = try await HermesSessionHistory.archiveFile(file, byteCount: bytes.count,
            sessionID: "native-session", identityHome: "/fixture/.hermes", recorder: recorder, afterMessageID: 7, runID: "woven-run")
        #expect(maximum == 8)
        let first = await capture.values.flatMap(\.records)
        #expect(first.first { $0.id == "message:7" }?.runID == nil)
        #expect(first.first { $0.id == "message:8" }?.runID == "woven-run")
        let retainedTool = try #require(first.first { $0.id == "message:7" })
        #expect(try HermesValue.decode(Data(retainedTool.payload.utf8))["content"].text == output)
        #expect(first.first { $0.id == "message:8" }?.payload.contains("native://attachment") == true)
        #expect(first.first { $0.id == "session.export.metadata" }?.payload.contains("older-store") == true)
        let manifest = try #require(first.first { $0.kind == "native-file.manifest" })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(manifest.payload.utf8)) as? [String: Any])
        #expect(object["sha256"] as? String == NativeHarnessArchive.digest(bytes))
        let parts = try #require(object["parts"] as? [[String: Any]])
        var restored = Data()
        for part in parts {
            #expect(part["byteOffset"] as? Int == restored.count)
            let chunk = try #require(first.first { $0.id == part["chunkID"] as? String })
            let value = try #require(try JSONSerialization.jsonObject(with: Data(chunk.payload.utf8)) as? [String: Any])
            let base64 = try #require(value["dataBase64"] as? String)
            let raw = try #require(Data(base64Encoded: base64))
            #expect(NativeHarnessArchive.digest(raw) == value["sha256"] as? String)
            restored.append(raw)
        }
        #expect(restored == bytes)
        _ = try await HermesSessionHistory.archiveFile(file, byteCount: bytes.count,
            sessionID: "native-session", identityHome: "/fixture/.hermes", recorder: recorder, afterMessageID: maximum, runID: "next-run")
        let all = await capture.values.flatMap(\.records)
        #expect(all.filter { $0.kind == "native-file.chunk" }.count == first.filter { $0.kind == "native-file.chunk" }.count * 2)
        #expect(Set(all.filter { $0.kind == "native-file.chunk" }.map(\.id)).count
            == Set(first.filter { $0.kind == "native-file.chunk" }.map(\.id)).count)
        #expect(Set(all.filter { $0.kind == "native-file.chunk" }.map(\.payload)).count
            == Set(first.filter { $0.kind == "native-file.chunk" }.map(\.payload)).count)
    }

    @Test func nativeHistoryScannerRejectsMalformedArraysAndWrongSessionExports() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"data\":{\"entries\":[{\"id\":\"row\"},]}}".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await PiNativeHistoryFrame.inspect(file) }
        let wrong = Data("{\"id\":\"different-session\",\"messages\":[]}".utf8)
        try wrong.write(to: file)
        let capture = NativeBatchCapture()
        await #expect(throws: (any Error).self) {
            try await HermesSessionHistory.archiveFile(file, byteCount: wrong.count, sessionID: "expected-session",
                identityHome: "/fixture/.hermes", recorder: { _, data in try await capture.append(data) }, afterMessageID: nil, runID: nil)
        }
        #expect(await capture.values.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func piCopiesStableNativeEntriesAndFinalStateThroughCurrentRPC(archiveFails: Bool) async throws {
        let capture = NativeBatchCapture()
        let fixture = PiPipeFixture(recorder: { direction, data in if direction == "native" { try await capture.append(data) } })
        let client = fixture.client
        let server = Task {
            defer { try? fixture.events.fileHandleForWriting.close() }
            let cursor = FixtureCommandReader(handle: fixture.commands.fileHandleForReading)
            var entryFetches = 0
            while let bytes = try await cursor.next() {
                let request = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let type = try #require(request["type"] as? String)
                var data: [String: Any] = [:]
                if type == "get_state" { data = ["sessionId": "native-session", "sessionFile": "/fixture/native-store.jsonl"] }
                if type == "get_entries" {
                    entryFetches += 1
                    if archiveFails, entryFetches > 1 {
                        try fixture.emit(["type": "response", "id": request["id"]!, "command": type, "success": false,
                            "error": "Native export temporarily unavailable"])
                        continue
                    }
                    if request["since"] == nil {
                        data = ["entries": [
                            ["id": "old-message", "type": "message", "message": ["role": "user", "content": String(repeating: "historical user 🧵 ", count: 70_000)]],
                            ["id": "compact-1", "type": "compaction", "summary": "exposed native compaction", "firstKeptEntryId": "old-message"]
                        ], "leafId": "compact-1"]
                    } else {
                        #expect(request["since"] as? String == "compact-1")
                        data = ["entries": [["id": "tool-result", "type": "message", "parentId": "compact-1",
                            "message": ["role": "toolResult", "toolCallId": "call-1", "content": [["type": "text", "text": "full native result"], ["type": "image", "data": "exposed-image-bytes", "mimeType": "image/png"]]]]], "leafId": "tool-result"]
                    }
                }
                try fixture.emit(["type": "response", "id": request["id"]!, "command": type, "success": true, "data": data])
                if type == "prompt" {
                    try fixture.emit(["type": "agent_start"])
                    for _ in 0..<2 { try fixture.emit(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": "same"]]) }
                    try fixture.emit(["type": "agent_settled"])
                }
            }
        }
        _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp/native-fixture"),
            existingSessionID: "native-session", title: nil, systemPrompt: nil)
        await client.setRunID("woven-run")
        if archiveFails {
            await #expect(throws: PiRPCClientError.self) { try await client.prompt("fixture prompt") }
        } else {
            #expect(try await client.prompt("fixture prompt") == .endTurn)
        }
        await client.shutdown()
        try await server.value
        let batches = await capture.values
        let records = batches.flatMap(\.records)
        #expect(records.contains { $0.kind == "native-file.manifest" })
        #expect(records.contains { $0.id == "entry:old-message" && $0.payload.contains("historical user 🧵") && $0.runID == nil })
        #expect(records.contains { $0.id == "entry:compact-1" && $0.payload.contains("exposed native compaction") && $0.runID == nil })
        #expect(records.contains { $0.id == "entry:tool-result" && $0.payload.contains("exposed-image-bytes") && $0.runID == "woven-run" } == !archiveFails)
        let repeated = records.filter { $0.kind == "message_update" }
        #expect(repeated.count == 2 && repeated[0].id != repeated[1].id)
        #expect(batches.allSatisfy { $0.sourceID == "pi:/fixture/native-store.jsonl" && $0.nativeSessionID == "native-session" })
        let state: [String: Any] = ["type": "response", "data": ["model": ["id": "custom", "headers": ["Authorization": "private-provider-token"]]]]
        let safe = try #require(PiRPCClient.credentialSafeRPCRecord(state, command: "get_state"))
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: safe), as: UTF8.self).contains("private-provider-token"))
        #expect(PiRPCClient.credentialSafeRPCRecord(["type": "message_end", "message": ["content": "native tool content"]], command: nil) == nil)
    }

    @Test func openCodeSnapshotsKeepUnknownAndNonTextContentWithoutCapturingConfiguration() throws {
        let long = String(repeating: "unabridged exposed tool output ", count: 10_000)
        let row: OpenCodeValue = ["id": "message-1", "type": "assistant", "content": .array([
            ["type": "reasoning", "text": "exposed thought"],
            ["type": "tool", "result": .string(long)],
            ["type": "image", "url": "native://image", "future_field": "retained"]
        ])]
        let batch = try #require(try OpenCodeHTTPClient.nativeSnapshot(path: "/api/session/native-session/message",
            value: ["data": .array([row])], sourceID: "remote-workspace:fixture"))
        #expect(batch.records.first?.id == "message:message-1")
        #expect(batch.records.first?.payload.contains(long) == true)
        #expect(batch.records.first?.payload.contains("native://image") == true)
        #expect(batch.records.first?.text?.contains("exposed thought") == true)
        #expect(try OpenCodeHTTPClient.nativeSnapshot(path: "/api/config", value: ["token": "private"], sourceID: "fixture") == nil)
    }

    @Test func openClawPreviewAndFullHydrationShareNativeIdentityAndKeepCoverage() throws {
        let metadata: GatewayJSONValue = .object(["id": .string("native-row"), "runId": .string("native-run"), "truncated": .bool(true)])
        let preview: GatewayJSONValue = .object(["role": .string("assistant"), "content": .string("preview"), "__openclaw": metadata])
        let first = try #require(try OpenClawGatewayClient.nativeHistoryBatch(method: "chat.history",
            params: .object(["offset": .number(0)]), value: .object(["messages": .array([preview]), "hasMore": .bool(true), "nextOffset": .number(100)]),
            sourceID: "gateway:physical-1", nativeSessionID: "agent:main:session"))
        var complete = preview.objectValue!
        complete["content"] = .array([.object(["type": .string("text"), "text": .string("full native text")]),
            .object(["type": .string("file"), "url": .string("native://attachment")])])
        complete["__openclaw"] = .object(["id": .string("native-row"), "runId": .string("native-run"), "truncated": .bool(false)])
        let full = try #require(try OpenClawGatewayClient.nativeHistoryBatch(method: "chat.message.get",
            params: .object(["messageId": .string("native-row")]), value: .object(["message": .object(complete)]),
            sourceID: "gateway:physical-1", nativeSessionID: "agent:main:session"))
        #expect(first.records.first?.id == full.records.first?.id)
        #expect(first.records.first?.completeness == "native-preview")
        #expect(full.records.first?.completeness == "native-export")
        #expect(full.records.first?.payload.contains("native://attachment") == true)
        #expect(!OpenClawGatewayClient.recordsRunTransport(method: "config.get"))
        #expect(!OpenClawGatewayClient.recordsRunTransport(method: "connect"))
        #expect(OpenClawGatewayClient.recordsRunTransport(method: "chat.history"))
    }

    @Test func hermesCopiesOriginalExportMetadataAndCredentialsStayOutOfTransportHistory() throws {
        let identity = HermesGatewayClient.identity(home: "/remote-workspaces/11111111-1111-1111-1111-111111111111/home/.hermes", storedID: "native-session", imported: true)
        let message: HermesValue = ["id": .number(7), "role": "tool", "content": "full result", "tool_call_id": "call-1", "unknown_metadata": ["preserved": .bool(true)]]
        let snapshot: HermesValue = ["id": "native-session", "messages": .array([message]), "compression_parent": "older-session"]
        let batch = try HermesSessionImport(identity: identity, title: "Imported", createdAt: .now, messages: [message], nativeSnapshot: snapshot).nativeArchiveBatch()
        #expect(batch.records.contains { $0.id == "message:7" && $0.payload.contains("unknown_metadata") })
        #expect(batch.records.contains { $0.id == "session.export" && $0.payload.contains("compression_parent") })
        let secret: HermesValue = ["id": "secret-response", "result": ["value": "do-not-store", "cancelled": .bool(false)]]
        #expect(!HermesGatewayRPC.credentialSafeFrame(secret, secretRequestIDs: ["secret-response"]).json.contains("do-not-store"))
        let sudo: HermesValue = ["method": "sudo.respond", "params": ["password": "private-password", "session_id": "native-session", "request_id": "r"]]
        #expect(!HermesGatewayRPC.credentialSafeFrame(sudo, secretRequestIDs: []).json.contains("private-password"))
        let tool: HermesValue = ["id": "normal-response", "result": ["password": "native tool content"]]
        #expect(HermesGatewayRPC.credentialSafeFrame(tool, secretRequestIDs: []) == tool)
    }
}

actor NativeBatchCapture {
    var values: [WorkspaceNativeRunRecordBatch] = []
    func append(_ data: Data) throws {
        values.append(try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data))
    }
}

actor NativeArchiveGate {
    var started = false, aborted = false, eventReferences = 0, fragments = 0
    var cancelled = false, emitted = false
    private var waiter: CheckedContinuation<Void, any Error>?
    func didAbort() { aborted = true }
    func framesEmitted() { emitted = true }
    func record(_ data: Data) async throws {
        let batch = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data)
        for row in batch.records {
            if row.kind == "native-file.manifest" { try await pause() }
            if row.kind == "message_end", row.completeness == "native-export-reference" {
                eventReferences += 1; #expect(row.runID == "woven-run")
            }
            if row.kind == "native-text-fragment" { fragments += 1 }
        }
    }
    func pause() async throws {
        started = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitFor(frames: Bool) async throws {
        for _ in 0..<20_000 {
            if frames ? emitted : started { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PiRPCClientError.archiveFailed("fixture archive did not progress")
    }
    func release() { waiter?.resume(); waiter = nil }
    func cancel() { cancelled = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
}

/// Tests large copies using a disk sink and bounded metadata, rather than
/// accidentally retaining every base64/native/search fragment in the fixture.
private actor NativeDiskCapture {
    let file: URL, output: FileHandle
    var fidelity = "", recordID = "", searchedEscapes = false
    var fragmentCount = 0, maximumPayloadBytes = 0
    private var reference: WorkspaceNativeRunRecord?
    private var byteCount = 0, hash = SHA256(), expectedHash = ""
    init(file: URL) throws {
        self.file = file
        FileManager.default.createFile(atPath: file.path, contents: nil)
        output = try FileHandle(forWritingTo: file)
    }
    func append(_ data: Data) throws {
        maximumPayloadBytes = max(maximumPayloadBytes, data.count)
        let batch = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data)
        for row in batch.records {
            if row.kind == "native-file.chunk" {
                let value = try HermesValue.decode(Data(row.payload.utf8))
                let bytes = try #require(Data(base64Encoded: value["dataBase64"].text))
                #expect(NativeHarnessArchive.digest(bytes) == value["sha256"].text)
                try output.write(contentsOf: bytes); hash.update(data: bytes); byteCount += bytes.count
            } else if row.kind == "native-file.manifest" {
                let value = try HermesValue.decode(Data(row.payload.utf8))
                expectedHash = value["sha256"].text; fidelity = value["byteFidelity"].text
                #expect(value["totalBytes"].number == Double(byteCount))
            } else if row.completeness == "native-export-reference" {
                reference = row; recordID = row.id
            } else if row.kind == "native-text-fragment" {
                fragmentCount += 1
                #expect(row.id == recordID)
                #expect(row.revision?.hasPrefix("projection:") == true)
                if row.text?.contains("needleé🧵") == true { searchedEscapes = true }
            }
        }
    }
    func closeAndValidate() throws {
        try output.close()
        #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == expectedHash)
        let row = try #require(reference), value = try HermesValue.decode(Data(row.payload.utf8))
        let offset = try #require(value["byteOffset"].number), length = try #require(value["byteCount"].number)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = Int(length), recordHash = SHA256()
        while remaining > 0 {
            let bytes = try #require(try input.read(upToCount: min(64 * 1_024, remaining)))
            #expect(!bytes.isEmpty); remaining -= bytes.count; recordHash.update(data: bytes)
        }
        #expect(recordHash.finalize().map { String(format: "%02x", $0) }.joined() == value["recordSHA256"].text)
    }
}
