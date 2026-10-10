import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct LocalACPFormTests {
    private var schema: [String: Any] { ["type": "object", "properties": [
        "question_0": ["type": "string", "title": "Choose", "oneOf": [["const": "raw-id", "title": "Display label", "description": "Detail", "_meta": ["preview": "Preview"]]]],
        "question_0_custom": ["type": "string", "title": "Other"],
        "many": ["type": "array", "items": ["anyOf": [["const": "a", "title": "Alpha"], ["const": "b", "title": "Beta"]]]],
    ]] }
    @Test func preservesClaudeValuesAnnotationsOptionalAnswersAndTypes() throws {
        let parsed = try LocalACPFormRequest.parse(message: "Questions", schema: JSONDecoder().decode(ACPJSONValue.self, from: JSONSerialization.data(withJSONObject: schema)))
        #expect(parsed.accepts([:]))
        #expect(parsed.accepts(["question_0": .string("raw-id"), "many": .strings(["b"])]))
        #expect(!parsed.accepts(["question_0": .string("Display label")]))
        #expect(!parsed.accepts(["question_0": .number(1)]))
        #expect(!parsed.accepts(["unknown": .string("value")]))
        let typed = try LocalACPFormRequest.parse(message: "Typed", schema: JSONDecoder().decode(ACPJSONValue.self, from: Data(#"{"type":"object","required":["text","flag","count"],"properties":{"text":{"type":"string","maxLength":2},"flag":{"type":"boolean","default":false},"count":{"type":"integer","minimum":0,"maximum":2}}}"#.utf8)))
        #expect(typed.accepts(["text": .string(""), "flag": .boolean(false), "count": .number(0)]))
        #expect(!typed.accepts(["text": .string("abc"), "flag": .boolean(false), "count": .number(1.5)]))
        #expect(!typed.accepts([:]))
    }
    @Test(arguments: [#"{"type":"object","properties":{"x":{"type":"string","pattern":"(a+)+"}}}"#,
                       #"{"type":"object","properties":{"x":{"type":"string","enum":["a"],"oneOf":[{"const":"b"}]}}}"#])
    func declinesUnsupportedOrConflictingConstraints(schema: String) throws {
        #expect(throws: (any Error).self) {
            try LocalACPFormRequest.parse(message: "Test", schema: JSONDecoder().decode(ACPJSONValue.self, from: Data(schema.utf8)))
        }
    }
    @Test func actualClaudeFormNegotiatesAndReturnsRawValues() async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [form(id: "form", session: "parent")], permissionResponseCount: 1)
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .claudeCode)
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        let stopReason = try await client.prompt("fixture", onInteraction: { request in
            guard case .form(let form) = request else { Issue.record("Expected form"); return .cancelled }
            #expect(form.fields.first(where: { $0.id == "question_0" })?.options.first?.id == "raw-id")
            return .formValues(["question_0": .string("raw-id")])
        })
        #expect(stopReason == .endTurn)
        await client.shutdown()
        let messages = try read(fixture)
        let initialize = try #require(messages.first(where: { $0["method"] as? String == "initialize" }))
        let capabilities = ((initialize["params"] as? [String: Any])?["clientCapabilities"] as? [String: Any])?["elicitation"] as? [String: Any]
        #expect(capabilities?["form"] != nil)
        let result = try #require(messages.first(where: { $0["id"] as? String == "form" })?["result"] as? [String: Any])
        #expect(result["action"] as? String == "accept")
        #expect(result["content"] as? [String: String] == ["question_0": "raw-id"])
    }
    @Test func foreignAndRequestScopedFormsCancelWithoutOpeningUI() async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [form(id: "foreign", session: "child"), form(id: "scoped", session: nil)], permissionResponseCount: 2)
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .claudeCode)
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        _ = try await client.prompt("fixture", onInteraction: { _ in Issue.record("Foreign form reached UI"); return .cancelled })
        await client.shutdown()
        let results = try read(fixture).filter { ["foreign", "scoped"].contains($0["id"] as? String ?? "") }
        #expect(results.count == 2)
        #expect(results.allSatisfy { ($0["result"] as? [String: String])?["action"] == "cancel" })
    }
    @Test func nativeCancellationReleasesUnansweredFormOnce() async throws {
        let opened = AsyncStream<Void>.makeStream()
        let fixture = try SessionRoutingFixture(promptFrames: [form(id: "held", session: "parent"),
            ["jsonrpc": "2.0", "method": "$/cancel_request", "params": ["requestId": "held"]]], permissionResponseCount: 1)
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .claudeCode, historyRecorder: { direction, data in
            if direction == "in", String(decoding: data, as: UTF8.self).contains("$/cancel_request") {
                for await _ in opened.stream { break }
            }
        })
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        _ = try await client.prompt("fixture", onInteraction: { _ in
            opened.continuation.yield(())
            try? await Task.sleep(for: .seconds(30))
            return .formValues(["question_0": .string("raw-id")])
        })
        await client.shutdown(); opened.continuation.finish()
        let results = try read(fixture).filter { $0["id"] as? String == "held" }
        #expect(results.count == 1)
        #expect((results.first?["result"] as? [String: String])?["action"] == "cancel")
    }
    private func form(id: String, session: String?) -> [String: Any] {
        var params: [String: Any] = ["mode": "form", "message": "Choose", "requestedSchema": schema]
        if let session { params["sessionId"] = session } else { params["requestId"] = "request-scope" }
        return ["jsonrpc": "2.0", "id": id, "method": "elicitation/create", "params": params]
    }
    private func read(_ fixture: SessionRoutingFixture) throws -> [[String: Any]] {
        try String(contentsOf: fixture.logURL, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
