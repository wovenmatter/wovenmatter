import SwiftUI

/// The Folders tab: folders across your machines and on this device, from
/// `model.app.workspace` (`WorkspaceStore`).
struct FoldersTab: View {
    @Bindable var model: MobileModel

    var body: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: "Folders")
            TabPlaceholder(glyph: .folder, title: "Folders")
        }
    }
}
