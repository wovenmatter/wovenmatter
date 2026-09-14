import Testing
@testable import WovenMatterClient

struct HermesSlashCommandsTests {
    @Test func catalogKeepsAllNativeCommandsAndOmitsDesktopOnlyControls() {
        let entries: [HermesValue] = (0..<12).map { .array([.string("/command\($0)"), .string("Native command")]) }
        let catalog: HermesValue = [
            "pairs": .array(entries + [
                .array(["/command0", "Duplicate"]), .array(["/terminal", "Terminal only"]),
                .array(["/density", "TUI display"]), .array(["/my-skill", "Installed skill"])
            ]),
            "commands": ["/terminal": ["desktop": "terminal"]],
            "categories": .array([["name": "TUI", "pairs": .array([.array(["/density", "TUI display"])])]])
        ]
        let commands = HermesSlashCommands.catalog(catalog)
        #expect(commands.count == 13)
        #expect(commands.last?.name == "my-skill")
        #expect(!commands.contains { ["terminal", "density"].contains($0.name) })
    }
}

extension HermesSlashCommandsTests {
    @Test func builtinFallbackRunsOnlyAfterExplicitNoHandler() async throws {
        let fixture = HermesCommandFixture([
            .failure(.rpc(code: 4018, message: "not a quick/plugin/bundle/skill command: help")),
            .success(["output": "Native help"])
        ])
        let result = try await HermesSlashCommands.dispatch("/help", sessionID: "session") { method, params in
            try await fixture.call(method, params)
        }
        #expect(result["output"].text == "Native help")
        #expect(await fixture.methods == ["command.dispatch", "slash.exec"])
    }

    @Test func failedQuickCommandIsNeverExecutedAgain() async throws {
        let fixture = HermesCommandFixture([.failure(.rpc(code: 4018, message: "quick command failed with exit code 1"))])
        do {
            _ = try await HermesSlashCommands.dispatch("/deploy", sessionID: "session") { method, params in
                try await fixture.call(method, params)
            }
            Issue.record("Failed native command must throw")
        } catch HermesGatewayError.rpc { }
        #expect(await fixture.methods == ["command.dispatch"])
    }

    @Test func aliasPreservesArgumentsAndReturnsDraftWithoutSubmitting() async throws {
        let fixture = HermesCommandFixture([
            .success(["type": "alias", "target": "undo"]),
            .success(["type": "prefill", "message": "Draft to edit"])
        ])
        let result = try await HermesSlashCommands.dispatch("/back 2", sessionID: "session") { method, params in
            try await fixture.call(method, params)
        }
        #expect(result["type"].text == "prefill")
        #expect(result["message"].text == "Draft to edit")
        #expect(await fixture.methods == ["command.dispatch", "command.dispatch"])
        #expect(await fixture.arguments.last?["name"].text == "undo")
        #expect(await fixture.arguments.last?["arg"].text == "2")
    }
}

private actor HermesCommandFixture {
    var methods: [String] = []
    var arguments: [HermesValue] = []
    private var responses: [Result<HermesValue, HermesGatewayError>]
    init(_ responses: [Result<HermesValue, HermesGatewayError>]) { self.responses = responses }
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        methods.append(method)
        arguments.append(params)
        guard !responses.isEmpty else { throw HermesGatewayError.message("Unexpected extra RPC") }
        return try responses.removeFirst().get()
    }
}
