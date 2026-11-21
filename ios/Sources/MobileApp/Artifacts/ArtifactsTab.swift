import SwiftUI

/// The Artifacts tab: the artifact open now (`model.artifactID`), from
/// `model.app.documents` (`DocumentsStore`).
struct ArtifactsTab: View {
    @Bindable var model: MobileModel

    var body: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: "Artifacts")
            TabPlaceholder(glyph: .fileText, title: "Artifacts")
        }
    }
}
