import SwiftUI
import WovenProtocol

/// Reused by standalone Artifacts and Page embeds. The host callback is always
/// bound to the original asset, including when it is embedded in another Page.
struct PersistentArtifactView: View {
    @Binding var document: NoteDocument
    var linkedDataJSON: String?
    var savedState: [String: ArtifactStateEntry]?
    var currentState: (() -> [String: ArtifactStateEntry])?
    var saveState: ((ArtifactStateEdit, Task<ArtifactStateWriteResult, any Error>?) -> Task<ArtifactStateWriteResult, any Error>)?
    var reportUnsaved: ((String, Bool) -> Void)?
    @State private var saveError: String?
    @State private var retrySignal = 0

    var body: some View {
        VStack(spacing: 0) {
            if document.databaseLink != nil {
                HStack {
                    Text("Live App").font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(WovenPalette.mutedForeground)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            HTMLArtifactView(html: document.html, linkedDataJSON: linkedDataJSON,
                persistentState: savedState ?? document.artifactState ?? [:],
                readState: { currentState?() ?? savedState ?? document.artifactState ?? [:] }, saveState: saveState,
                onSaveError: { saveError = $0 }, reportUnsaved: reportUnsaved, retrySignal: retrySignal)
            if let saveError {
                HStack(alignment: .top, spacing: 8) {
                    Text(saveError).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Retry saving") { retrySignal += 1 }
                        .buttonStyle(WovenQuietButtonStyle())
                }
                .foregroundStyle(WovenPalette.danger)
                .padding(12)
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: document.html) { _, _ in saveError = nil }
    }
}

/// An App with no code yet. It is built from the chat beside it, like any
/// other edit: the open App is shared with whichever agent the chat uses.
/// Where the chat is not beside it, `openChat` goes to it.
struct AppBuildPrompt: View {
    var openChat: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text("Ask an agent to build this").font(.system(size: 17, weight: .semibold))
            Text("Describe the app in the chat. The agent you have open builds it here and can connect it to live data.")
                .font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let openChat {
                Button("Open chat", action: openChat)
                    .buttonStyle(WovenQuietButtonStyle())
                    .accessibilityIdentifier("app-open-chat")
            }
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
