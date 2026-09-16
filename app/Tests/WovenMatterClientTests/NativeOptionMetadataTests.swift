import Testing
@testable import WovenMatterClient

struct NativeOptionMetadataTests {
    @Test func gptPresentationRetainsFamilyWithoutChangingOtherNamesOrIDs() {
        for (id, name, expected) in [
            ("gpt-6-astra", "6 Astra", "GPT 6 Astra"),
            ("gpt-5.6-sol", "5.6 Sol", "GPT 5.6 Sol"),
            ("gpt-daybreak-blue-latest", "Daybreak Blue", "GPT Daybreak Blue"),
            ("gpt-5.5", "GPT 5.5", "GPT 5.5"),
            ("gpt-5.5", "gpt-5.5", "gpt-5.5"),
            ("sonnet", "Sonnet", "Sonnet"),
            ("claude-opus-4-8", "Opus 4.8", "Opus 4.8"),
            ("default", "Default", "Default")
        ] {
            let metadata = SessionOptionMetadata(name: name)
            #expect(SessionOptionMetadata.modelLabel(id: id, metadata: metadata) == expected)
            #expect(metadata.name == name)
        }
        #expect(SessionOptionMetadata.modelLabel(id: "gpt-6-astra", metadata: nil) == "gpt-6-astra")
    }

    @Test func hermesPreservesWireIDsAndUsesOnlyNativeReasoningCapabilities() {
        let options: HermesValue = [
            "model": "shared",
            "provider": "provider-a",
            "providers": .array([
                ["slug": "provider-a", "name": "Provider A", "models": .array(["shared"]),
                 "capabilities": ["shared": ["reasoning": .bool(true), "can_disable_reasoning": .bool(true)]]],
                ["slug": "provider-b", "name": "Provider B", "models": .array(["shared"]),
                 "capabilities": ["shared": ["reasoning": .bool(false)]]]
            ])
        ]
        let configuration = HermesGatewayClient.configuration(
            options: options,
            reasoning: ["value": "high"]
        )
        #expect(configuration.model == "shared --provider provider-a")
        #expect(configuration.modelOptions == ["shared --provider provider-a", "shared --provider provider-b"])
        #expect(configuration.modelOptionMetadata["shared --provider provider-a"] ==
            SessionOptionMetadata(name: "shared", description: "Provider A"))
        #expect(configuration.thinking == "high")
        #expect(configuration.thinkingOptions == [
            "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
        ])

        let mandatory = HermesGatewayClient.configuration(
            options: [
                "model": "shared", "provider": "provider-a",
                "providers": .array([
                    ["slug": "provider-a", "models": .array(["shared"]),
                     "capabilities": ["shared": ["reasoning": .bool(true), "can_disable_reasoning": .bool(false)]]]
                ])
            ],
            reasoning: ["value": "high"]
        )
        #expect(mandatory.thinkingOptions == [
            "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
        ])

        let unsupported = HermesGatewayClient.configuration(
            options: ["model": "shared", "provider": "provider-b", "providers": options["providers"]],
            reasoning: ["value": "high"]
        )
        #expect(unsupported.thinking == nil)
        #expect(unsupported.thinkingOptions.isEmpty)
    }

    @Test func openCodePreservesNativeModelAndSelectedVariantPresentation() {
        let models: [OpenCodeValue] = [
            ["id": "same", "providerID": "first", "name": "First Model", "description": "First description",
             "variants": .array([["id": "deep", "name": "Deep", "description": "More reasoning"]])],
            ["id": "same", "providerID": "second", "name": "Second Model", "description": "Second description"]
        ]
        let metadata = OpenCodeComposerMetadata.metadata(
            session: ["id": "session", "model": ["id": "same", "providerID": "first", "variant": "deep"]],
            models: models
        )
        #expect(metadata.modelOptionMetadata?["first/same"] ==
            SessionOptionMetadata(name: "First Model", description: "First description"))
        #expect(metadata.modelOptionMetadata?["second/same"] ==
            SessionOptionMetadata(name: "Second Model", description: "Second description"))
        #expect(metadata.thinkingOptionMetadata?["deep"] ==
            SessionOptionMetadata(name: "Deep", description: "More reasoning"))
        #expect(metadata.thinkingOptionMetadata?["default"] == nil)
    }
}
