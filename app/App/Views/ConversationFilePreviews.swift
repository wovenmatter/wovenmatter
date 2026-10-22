import SwiftUI
import WovenMatterCore

/// Only explicit file handbacks get buttons. Opening resolves the message's retained
/// Library identity, so a path in agent text never becomes an arbitrary local read.
struct ConversationFilePreviews: View {
    let content: String
    let onOpen: (String) -> Void

    private var files: [LibraryAsset] {
        LibraryLinkDiscovery.links(in: content).filter { LibraryFileReference.path($0.source) != nil }
    }

    var body: some View {
        if !files.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
    }

    private var buttons: some View {
        ForEach(files, id: \.source) { file in
            Button { onOpen(file.source) } label: {
                Label(file.title, systemImage: file.kind == .photo ? "photo" : "doc.richtext")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(DashboardQuietButtonStyle())
            .help("Preview \(file.title)")
            .accessibilityLabel("Preview \(file.title)")
        }
    }
}
