import SwiftUI

struct DictationMicrophone: View {
    let editor: DictationEditor
    var onActivate: () -> Void = {}
    private var dictation: DictationModel { .shared }
    var body: some View {
        Button {
            onActivate()
            if dictation.retainedTranscript != nil { dictation.insertRetained(into: editor) }
            else { dictation.toggle(editor: editor) }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic")
                .font(.system(size: 16))
                .foregroundStyle(dictation.isRecording ? DashboardPalette.danger : DashboardPalette.foreground)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .disabled(dictation.phase == .finishing)
        .accessibilityLabel(dictation.retainedTranscript != nil ? "Insert retained dictation here" : dictation.isRecording ? "Stop recording and insert here" : "Start dictation")
        .help(dictation.retainedTranscript != nil ? "Insert retained dictation here" : dictation.isRecording ? "Stop recording and insert here" : "Dictate with your Grok subscription")
    }
}

struct DictationFeedback: View {
    private var dictation: DictationModel { .shared }
    var body: some View {
        if dictation.isBusy || dictation.error != nil || dictation.retainedTranscript != nil {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if !dictation.preview.isEmpty { Text(dictation.preview).font(.caption).lineLimit(2) }
                    if let error = dictation.error { Text(error).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    if let transcript = dictation.retainedTranscript { Text(transcript).font(.caption).lineLimit(4).textSelection(.enabled) }
                }
                Spacer(minLength: 0)
                Button(dictation.isBusy ? "Cancel" : dictation.retainedTranscript == nil ? "Dismiss" : "Discard") { dictation.cancel() }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
            .padding(12)
            .background(DashboardPalette.background)
            .clipShape(DashboardShapes.card)
            .frame(maxWidth: 540)
        }
    }
    private var title: String {
        switch dictation.phase {
        case .connecting: "Connecting dictation…"
        case .recording: "Recording · Stop in any conversation or note to insert there"
        case .finishing: "Finishing transcription…"
        case .idle: dictation.retainedTranscript == nil ? "Dictation" : "Transcript ready"
        }
    }
}
