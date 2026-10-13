import SwiftUI
import CompanionClient

struct LibrarySyncStatusPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    List {
      Section {
        LabeledContent("Central Mac", value: model.online ? "Connected" : "Disconnected")
        if let contacted = model.synchronizationStatus.lastContactAt {
          LabeledContent("Last connected") { Text(contacted, style: .relative) }
        }
      }
      ForEach(MobileSyncLane.allCases, id: \.self) { lane in
        let status = model.synchronizationStatus.lanes[lane] ?? .init()
        Section(lane.title) {
          LabeledContent("Status", value: status.label)
          if status.pendingCount > 0 { LabeledContent("Pending", value: String(status.pendingCount)) }
          if status.conflictCount > 0 { LabeledContent("Conflicts", value: String(status.conflictCount)) }
          if let date = status.lastSuccessfulSync {
            LabeledContent("Last synced") { Text(date, style: .relative) }
          }
          if let error = status.lastError { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
        }
      }
      if model.hasPendingRecovery { NavigationLink("Pending changes") { SyncRecoveryPane(model: model) } }
    }.mobileNavigationPage("Sync status")
      .task { await model.refreshSynchronizationStatus() }
      .refreshable { await model.refresh(); await model.refreshSynchronizationStatus() }
  }
}

private extension MobileSyncLane {
  var title: String {
    switch self {
    case .library: "Notes and folders"
    case .calendar: "Calendar and scheduled tasks"
    case .journal: "Agent history"
    case .artifacts: "Saved artifacts"
    case .offlineCache: "Offline copies"
    }
  }
}
private extension MobileSyncLaneStatus {
  var label: String {
    if conflictCount > 0 { return "Needs attention" }
    return switch phase {
    case .idle: "Saved on this device"
    case .syncing: "Syncing"
    case .current: "Synced"
    case .pending: "Waiting to sync"
    case .blocked: "Needs attention"
    case .unsupported: "Available on this device"
    }
  }
}
