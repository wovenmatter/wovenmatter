import SwiftUI
import WovenMatterClient

/// The answer lives only in transient view/continuation state, never chat history.
struct DashboardLocalSecretCard: View {
    let prompt: String
    let onResolve: (LocalACPInteractionResponse) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt).font(.system(size: 13, weight: .medium))
            SecureField("Secret", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Button("Submit") { submit() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(value.isEmpty)
                Button("Cancel") { value = ""; onResolve(.cancelled) }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: 768, alignment: .leading)
        .background(DashboardPalette.background)
        .clipShape(DashboardShapes.card)
        .onDisappear { value = "" }
    }
    private func submit() {
        guard !value.isEmpty else { return }
        let answer = value
        value = ""
        onResolve(.secret(answer))
    }
}
