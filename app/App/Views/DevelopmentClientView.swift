import SwiftUI

/// The production desktop surface backed by this instance's execution model and
/// synchronized replica. Enrollment remains in the existing connection UI.
struct DevelopmentClientView: View {
    @Bindable var application: ApplicationModel
    private var client: CentralLibraryClientModel { application.libraryClient }
    @State private var showsConnection = false
    @State private var showsConflicts = false

    var body: some View {
        Group {
            if let execution = client.localExecution {
                RootView(model: execution.model)
                    .toolbar {
                        ToolbarItem {
                            Button(DevelopmentLaunch.displayName) { showsConnection = true }
                                .help("Live library · " + client.status)
                        }
                        if !client.state.conflicts.isEmpty {
                            ToolbarItem {
                                Button("Saved conflicts") { showsConflicts = true }
                            }
                        }
                    }
            } else {
                CentralLibraryClientSettings(model: client, application: application)
            }
        }
        .sheet(isPresented: $showsConnection) {
            CentralLibraryClientSettings(model: client, application: application)
                .frame(minWidth: 560, minHeight: 480)
        }
        .task { await client.run() }
        .alert("Woven Matter", isPresented: Binding(
            get: { client.errorMessage != nil }, set: { if !$0 { client.errorMessage = nil } }
        )) {
            Button("OK") { client.errorMessage = nil }
        } message: { Text(client.errorMessage ?? "") }
        .sheet(isPresented: $showsConflicts) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Saved conflicts").font(.headline)
                ForEach(client.state.conflicts.keys.sorted(), id: \.self) { id in
                    if let conflict = client.state.conflicts[id] {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conflict.local.title)
                                Text(conflict.reason).font(.caption)
                            }
                            Spacer()
                            Button("Keep as copy") { Task { await client.preserveConflict(id) } }
                        }
                    }
                }
                Button("Done") { showsConflicts = false }
            }
            .padding(24).frame(minWidth: 480)
        }
    }
}
