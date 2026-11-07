import SwiftUI
import WovenMatterCore

/// Reused by standalone Artifacts and Page embeds. The host callback is always
/// bound to the original asset, including when it is embedded in another Page.
struct DashboardPersistentArtifactView: View {
    @Binding var document: NoteDocument
    var linkedDataJSON: String?
    var savedState: [String: ArtifactStateEntry]?
    var currentState: (() -> [String: ArtifactStateEntry])?
    var saveState: ((ArtifactStateEdit, Task<ArtifactStateWriteResult, any Error>?) -> Task<ArtifactStateWriteResult, any Error>)?
    @State private var saveError: String?
    @State private var retrySignal = 0

    var body: some View {
        VStack(spacing: 0) {
            if document.databaseLink != nil {
                HStack {
                    Text("Live Artifact").font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            DashboardHTMLArtifactView(html: document.html, linkedDataJSON: linkedDataJSON,
                persistentState: savedState ?? document.artifactState ?? [:],
                readState: { currentState?() ?? savedState ?? document.artifactState ?? [:] }, saveState: saveState,
                onSaveError: { saveError = $0 }, retrySignal: retrySignal)
            if let saveError {
                HStack(alignment: .top, spacing: 8) {
                    Text(saveError).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Retry saving") { retrySignal += 1 }
                        .buttonStyle(DashboardQuietButtonStyle())
                }
                .foregroundStyle(DashboardPalette.danger)
                .padding(12)
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: document.html) { _, _ in saveError = nil }
    }
}
