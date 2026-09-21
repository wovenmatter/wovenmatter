import AppKit
import SwiftUI
import WovenMatterClient

/// Only pending interactions and failures belong above the shared composer.
struct OpenCodeConversationControls: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isLocalSession(conversationID) {
                Text("Saved transcript · Start a new OpenCode chat to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let error = model.errors[conversationID] ?? model.error {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
                OpenCodeInteractions(model: model, conversationID: conversationID)
                ForEach((try? model.store.database.openCodeUncertainSubmissions(conversationID: conversationID)) ?? [], id: \.self) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Input outcome is uncertain").fontWeight(.semibold)
                        Text(item["payload"]["text"].text).textSelection(.enabled)
                        Text("This input has not been resent. Check the conversation in OpenCode before sending it again.")
                        Button("Acknowledge") { model.perform {
                            try model.store.database.saveOpenCodeSubmission(conversationID: conversationID, id: item["id"].text, payload: item["payload"], status: "acknowledged")
                            if let link = model.links[conversationID] { try await model.coordinator.refresh(link) }
                        } }
                    }.font(.caption)
                }
            }
        }
        .task(id: conversationID + ":" + (model.statuses[conversationID] ?? "")) {
            if model.isLocalSession(conversationID), model.statuses[conversationID] == "Connected" {
                do { try await model.refreshCatalog(conversationID) }
                catch { model.error = error.localizedDescription }
            }
        }
    }
}

struct OpenCodeMessageMedia: View {
    let model: OpenCodeModel
    let conversationID: String
    let messageID: String
    var fileIndex: Int? = nil
    private var files: [OpenCodeValue] {
        guard let message = model.snapshots[conversationID]?.messages.first(where: { $0["id"].text == messageID }) else { return [] }
        return Self.files(in: message)
    }
    static func files(in message: OpenCodeValue) -> [OpenCodeValue] {
        return message["files"].array + message["content"].array.flatMap { $0["state"]["content"].array.filter { $0["type"].text == "file" } }
    }
    var body: some View {
        ForEach(Array(files.enumerated()).filter { fileIndex == nil || $0.offset == fileIndex }, id: \.offset) { _, file in
            OpenCodeMediaItem(model: model, conversationID: conversationID, file: file)
        }
    }
}

private struct OpenCodeMediaItem: View {
    let model: OpenCodeModel
    let conversationID: String
    let file: OpenCodeValue
    @State private var preview: NSImage?
    @State private var failure: String?
    private var embedded: Data? {
        if let data = file["data"].string { return Data(base64Encoded: data) }
        let uri = file["uri"].text
        if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") { return Data(base64Encoded: String(uri[uri.index(after: comma)...])) }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = preview ?? embedded.flatMap({ NSImage(data: $0) }) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 540, maxHeight: 320)
            }
            HStack {
                Label(file["name"].string ?? file["mime"].string ?? "Attachment", systemImage: "paperclip")
                Button("Save…") { model.perform {
                    let bytes = try await contents()
                    let panel = NSSavePanel(); panel.nameFieldStringValue = file["name"].string ?? "opencode-attachment"
                    if panel.runModal() == .OK, let url = panel.url { try bytes.write(to: url, options: .atomic) }
                } }
                if embedded == nil { Button("Preview") { model.perform {
                    do { preview = NSImage(data: try await contents()); if preview == nil { failure = "Use Save to inspect this file." } }
                    catch { failure = error.localizedDescription }
                } } }
            }.font(.caption)
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func contents() async throws -> Data {
        if let embedded { return embedded }
        let uri = file["uri"].string ?? file["source"]["uri"].text
        guard let location = URL(string: uri), location.isFileURL, let link = model.links[conversationID] else {
            throw OpenCodeError.message("This attachment has no embedded content or server file reference.")
        }
        return try await model.coordinator.readFile(connectionID: link.connectionID, path: location.path, query: model.locationQuery(conversationID)).0
    }
}
