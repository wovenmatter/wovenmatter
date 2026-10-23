import SwiftUI
import UIKit
import WovenMatterCompanion

struct DictationHistoryPane: View {
  let model: CompanionModel
  @State private var records: [DictationRecord] = []
  private let pageSize = 20
  @State private var page = 0
  @State private var hasNextPage = false
  @State private var loaded = false
  @State private var error: String?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        Text("Your completed dictations. Click on an entry to see it in full.")
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
        if !records.isEmpty || page > 0 {
          HStack(spacing: 8) {
            if page > 0 {
              Button { changePage(to: 0) } label: {
                DashboardLucideIcon(glyph: .chevronsLeft, size: 18).frame(width: 44, height: 44)
              }.accessibilityLabel("First page")
            } else {
              Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
            Button { changePage(to: page - 1) } label: {
              DashboardLucideIcon(glyph: .arrowLeft, size: 18).frame(width: 44, height: 44)
            }.disabled(page == 0).accessibilityLabel("Previous page")
            Text("Page \(page + 1)").font(.subheadline).monospacedDigit()
              .foregroundStyle(DashboardPalette.mutedForeground).fixedSize()
            Button { changePage(to: page + 1) } label: {
              DashboardLucideIcon(glyph: .arrowRight, size: 18).frame(width: 44, height: 44)
            }.disabled(!hasNextPage).accessibilityLabel("Next page")
            // Balance the first-page slot so the page number stays centered.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
          }.buttonStyle(DashboardIconButtonStyle()).frame(maxWidth: .infinity)
        }
      }.padding(16)
    }.scrollIndicators(.never).mobileNavigationPage("Dictation")
      .id(page)
      .task(id: page) {
        repeat {
          await reload()
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
        } while !Task.isCancelled
      }
      .onChange(of: DictationSession.shared.historyRevision) { _, _ in Task { await reload() } }
  }
  private func changePage(to newPage: Int) {
    records = []; loaded = false; hasNextPage = false; error = nil
    page = newPage
  }
  private func reload() async {
    let requestedPage = page
    do {
      guard let store = model.store else { throw DictationHistoryError.invalidRecord }
      let fetched = try await store.dictations.records(limit: pageSize + 1, offset: requestedPage * pageSize)
      guard !Task.isCancelled, page == requestedPage else { return }
      records = Array(fetched.prefix(pageSize)); hasNextPage = fetched.count > pageSize
      loaded = true; error = nil
    } catch {
      guard !Task.isCancelled, page == requestedPage else { return }
      self.error = error.localizedDescription; loaded = true
    }
  }
}
private struct MobileDictationHistoryRow: View {
  let record: DictationRecord
  @State private var expanded = false
  @State private var copied = false
  var body: some View {
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
      Button {
        UIPasteboard.general.string = record.text; copied = true
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 11.5, weight: .medium))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }.buttonStyle(DashboardIconButtonStyle()).accessibilityLabel(copied ? "Copied dictation" : "Copy dictation")
        .task(id: copied) {
          guard copied else { return }
          do { try await Task.sleep(for: .seconds(2)); copied = false } catch { }
        }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
      .background(DashboardPalette.background, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
  }
}
