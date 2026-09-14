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
