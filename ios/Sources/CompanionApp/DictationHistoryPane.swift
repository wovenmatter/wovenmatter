import SwiftUI
import UIKit
import WovenMatterCompanion

struct DictationHistoryPane: View {
  let model: CompanionModel
  @State private var records: [DictationRecord] = []
  @State private var limit = 100
  @State private var loaded = false
  @State private var error: String?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        Text("Your completed dictations, newest first. Tap an entry to read it in full.")
          .font(.subheadline).foregroundStyle(DashboardPalette.mutedForeground)
        if let problem = DictationSession.shared.historyError {
          Text(problem).foregroundStyle(DashboardPalette.danger)
          Button("Retry saving") { DictationSession.shared.retrySavingHistory() }
        }
        if let error { Text(error).foregroundStyle(DashboardPalette.danger) }
        if !loaded { ProgressView() }
        else if records.isEmpty {
          Text("No dictations yet").font(.headline)
          Text("Completed dictations will appear here when you stop recording.").font(.subheadline)
        }
        ForEach(records) { record in MobileDictationHistoryRow(record: record) }
        if records.count == limit { Button("Show more") { limit += 100 } }
      }.padding(16)
    }.scrollIndicators(.never).mobileNavigationPage("Dictation")
      .task(id: limit) {
        repeat {
          await reload()
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
        } while !Task.isCancelled
      }
      .onChange(of: DictationSession.shared.historyRevision) { _, _ in Task { await reload() } }
  }
  private func reload() async {
    do {
      guard let store = model.store else { throw DictationHistoryError.invalidRecord }
      records = try await store.dictations.records(limit: limit); loaded = true; error = nil
    } catch { self.error = error.localizedDescription; loaded = true }
  }
}
private struct MobileDictationHistoryRow: View {
  let record: DictationRecord
  @State private var expanded = false
  @State private var copied = false
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        if expanded {
          Text(record.text).textSelection(.enabled)
          Button("Show less") { expanded = false }.font(.subheadline)
        } else {
          Button { expanded = true } label: {
            Text(record.text).lineLimit(3).multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.plain).accessibilityHint("Show full dictation")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button {
        UIPasteboard.general.string = record.text; copied = true
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
      }.buttonStyle(DashboardIconButtonStyle()).accessibilityLabel(copied ? "Copied dictation" : "Copy dictation")
        .task(id: copied) {
          guard copied else { return }
          do { try await Task.sleep(for: .seconds(2)); copied = false } catch { }
        }
    }.padding(12).background(DashboardPalette.background, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
  }
}
