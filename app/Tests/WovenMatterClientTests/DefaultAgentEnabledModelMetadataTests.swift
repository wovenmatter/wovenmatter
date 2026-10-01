import Foundation
import Testing
@testable import WovenMatterClient

struct DefaultAgentEnabledModelMetadataTests {
    @Test func typedChatCatalogKeepsNamesScopedToChatModels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pi-model-names-\(UUID().uuidString)")
        let data = root.appending(path: "node_modules/@earendil-works/pi-ai/dist/providers/data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = #"""
        {
          "responses": {
            "chat:shared": {"type":"chat", "name":"Chat Model"},
            "image:shared": {"type":"image", "name":"Image Model"},
            "classifier:shared": {"type":"classifier", "name":"Classifier Model"},
            "chat:ambiguous": {"type":"chat", "name":"First Name"},
            "image:only-image": {"type":"image", "name":"Image Only"},
            "invalid": {"type":"image", "name":"Not Chat"}
          },
          "completions": {
            "chat:shared": {"type":"chat", "name":"Chat Model"},
            "chat:ambiguous": {"type":"chat", "name":"Second Name"},
            "legacy": {"name":"Legacy Model"}
          }
        }
        """#
        try Data(catalog.utf8).write(to: data.appending(path: "openai.json"))
        let names = await DefaultAgentEnabledModelMetadata.names(for: [
            "openai/shared", "openai/ambiguous", "openai/only-image", "openai/invalid",
            "openai/legacy", "openai/missing", "unknown/shared"
        ], resources: root, local: false)
        #expect(names == ["openai/shared": "Chat Model", "openai/legacy": "Legacy Model"])
    }

    @Test func xaiAPIRouteUsesTypedXaiCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pi-xai-names-\(UUID().uuidString)")
        let data = root.appending(path: "node_modules/@earendil-works/pi-ai/dist/providers/data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"responses":{"chat:grok":{"type":"chat","name":"Grok"}}}"#.utf8)
            .write(to: data.appending(path: "xai.json"))
        let names = await DefaultAgentEnabledModelMetadata.names(for: ["xai-api/grok", "xai/grok"], resources: root, local: false)
        #expect(names == ["xai-api/grok": "Grok", "xai/grok": "Grok"])
    }
}
