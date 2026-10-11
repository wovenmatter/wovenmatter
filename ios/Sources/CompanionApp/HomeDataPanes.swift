import SwiftUI
import CompanionClient
import WovenMatterCompanion

struct ScheduledTasksPane: View {
  @Bindable var model: CompanionModel
  @State private var items: [CompanionScheduledTaskItem] = []
  @State private var filter = "All"
  @State private var loading = false
  @State private var generation = 0
  @State private var loaded = false
  @State private var failure: String?
  private var scope: String { "\(model.state.workspaceID ?? ""):\(model.online)" }
  private var visible: [CompanionScheduledTaskItem] {
    items.filter { filter == "All" || ($0.showsOnCalendar ? "Calendar" : "Scheduled") == filter }
  }
  var body: some View {
    List {
      Section {
        DashboardSegmentedSelector(options: ["All", "Scheduled", "Calendar"], selection: $filter) { $0 }
          .accessibilityLabel("Task type")
      }.listRowBackground(Color.clear)
      if let failure { HomeDataError(message: failure) }
      if loading && !loaded { ProgressView("Loading tasks…") }
      ForEach(visible) { item in
        NavigationLink {
          CalendarEventSheet(model: model, event: item.event)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            Label(item.event.draft.title, glyph: .calendarClock).font(.headline)
            Text([item.runtimeName, item.workspaceName].joined(separator: " · "))
              .font(.subheadline).foregroundStyle(DashboardPalette.mutedForeground)
            Text(item.event.draft.startsAt, format: .dateTime.month().day().hour().minute())
              .font(.caption).monospacedDigit()
            if let unit = item.event.draft.recurrenceUnit {
              Text(recurrence(unit, interval: item.event.draft.recurrenceInterval))
                .font(.caption).foregroundStyle(DashboardPalette.calendarRecurringTask)
            }
            if let status = item.event.status {
              Text(status).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            }
          }.padding(.vertical, 5)
        }
      }
      if visible.isEmpty && !loading && failure == nil {
        Text(loaded ? "No scheduled tasks." : "No tasks loaded.").foregroundStyle(DashboardPalette.mutedForeground)
      }
    }
    .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.never)
    .navigationTitle("Scheduled tasks").navigationBarTitleDisplayMode(.inline)
    .mobilePageSurface().toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button { Task { await load() } } label: { DashboardLucideIcon(glyph: .rotate, size: 20) }
          .disabled(!model.online || loading).accessibilityLabel("Refresh scheduled tasks")
        NavigationLink { CalendarEventSheet(model: model, event: nil, newTask: true) } label: {
          DashboardLucideIcon(glyph: .plus, size: 20)
        }.disabled(!model.online).accessibilityLabel("New scheduled task")
      }
    }
    .refreshable { await load() }
    .task(id: scope) { generation += 1; loading = false; items = []; loaded = false; failure = nil; await load() }
  }
  private func recurrence(_ unit: String, interval: Int) -> String {
    interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
  }
  private func load() async {
    guard model.online else { return }
    generation += 1; let requestGeneration = generation
    let expected = scope; loading = true; failure = nil
    defer { if requestGeneration == generation { loading = false } }
    do {
      guard case .scheduledTasks(let values) = try await model.workspace(.scheduledTasks) else { throw MobileConnectionError.invalidResponse }
      guard expected == scope, requestGeneration == generation, !Task.isCancelled else { return }
      items = values; loaded = true
    } catch { if expected == scope, requestGeneration == generation, !Task.isCancelled { failure = error.localizedDescription } }
  }
}

struct DatabasesPane: View {
  @Bindable var model: CompanionModel
  @State private var sources: [CompanionDatabaseSource] = []
  @State private var search = ""
  @State private var loading = false
  @State private var generation = 0
  @State private var loaded = false
  @State private var failure: String?
  private var scope: String { "\(model.state.workspaceID ?? ""):\(model.online)" }
  var body: some View {
    List {
      if let failure { HomeDataError(message: failure) }
      if loading && !loaded { ProgressView("Loading databases…") }
      ForEach(sources) { source in
        Section(source.name) {
          if let error = source.error { HomeDataError(message: error) }
          ForEach(source.databases.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { database in
            NavigationLink {
              DatabaseDetailPane(model: model, database: database, source: source)
            } label: {
              HStack(spacing: 12) {
                DashboardLucideIcon(glyph: .database, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                  Text(database.name).font(.headline)
                  Text(database.format == "No preference" ? "Database" : database.format)
                    .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                }
              }.padding(.vertical, 5)
            }
          }
          if source.databases.isEmpty && source.error == nil {
            Text("No databases.").foregroundStyle(DashboardPalette.mutedForeground)
          }
        }
      }
      if sources.isEmpty && !loading && failure == nil {
        Text(loaded ? "No databases." : "No databases loaded.").foregroundStyle(DashboardPalette.mutedForeground)
      }
    }
    .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.never)
    .searchable(text: $search, prompt: "Search databases")
    .navigationTitle("Databases").navigationBarTitleDisplayMode(.inline).mobilePageSurface().toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { Task { await load() } } label: { DashboardLucideIcon(glyph: .rotate, size: 20) }
          .disabled(!model.online || loading).accessibilityLabel("Refresh databases")
      }
    }
    .refreshable { await load() }
    .task(id: scope) { generation += 1; loading = false; sources = []; loaded = false; failure = nil; await load() }
  }
  private func load() async {
    guard model.online else { return }
    generation += 1; let requestGeneration = generation
    let expected = scope; loading = true; failure = nil
    defer { if requestGeneration == generation { loading = false } }
    do {
      guard case .databases(let values) = try await model.workspace(.databases) else { throw MobileConnectionError.invalidResponse }
      guard expected == scope, requestGeneration == generation, !Task.isCancelled else { return }
      sources = values; loaded = true
    } catch { if expected == scope, requestGeneration == generation, !Task.isCancelled { failure = error.localizedDescription } }
  }
}

private struct DatabaseDetailPane: View {
  @Bindable var model: CompanionModel
  let database: CompanionDatabaseItem
  let source: CompanionDatabaseSource
  private var linkedNotes: [CompanionNote] {
    model.notes.filter { note in
      guard let document = RichDocumentEditing.document(note.content) else { return false }
      let links = [document.databaseLink].compactMap { $0 } + document.blocks.compactMap { block -> DatabaseArtifactLink? in
        if case .table(let table) = block { return table.databaseLink }; return nil
      }
      return links.contains { $0.sourceID + ":" + $0.databaseID == database.id }
    }
  }
  var body: some View {
    List {
      Section {
        LabeledContent("Workspace", value: source.name)
        LabeledContent("Format", value: database.format)
        if database.isExternal { LabeledContent("Location", value: "Linked folder") }
      }
      if !linkedNotes.isEmpty {
        Section("Linked notes") {
          ForEach(linkedNotes) { note in
            Button { Task { await model.openNote(note.id) } } label: { Label(note.title, glyph: .fileText) }
          }
        }
      }
    }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollIndicators(.never)
      .navigationTitle(database.name).navigationBarTitleDisplayMode(.inline)
  }
}

struct UsagePane: View {
  @Bindable var model: CompanionModel
  @State private var samples: [CompanionUsageSample] = []
  @State private var days = 7
  @State private var source = "device"
  @State private var intervalEnd = Date()
  @State private var offset = 0
  @State private var hasMore = false
  @State private var loading = false
  @State private var generation = 0
  @State private var loaded = false
  @State private var failure: String?
  private var scope: String { "\(source):\(model.state.workspaceID ?? ""):\(model.online):\(days)" }
  private var available: Bool { source == "device" ? model.store != nil : model.online }
  private var totalTokens: Int64 { samples.reduce(0) { $0 + $1.totalTokens } }
  private var groups: [(name: String, tokens: Int64, requests: Int)] {
    Dictionary(grouping: samples, by: { $0.model }).map { name, values in
      (name, values.reduce(0) { $0 + $1.totalTokens }, values.reduce(0) { $0 + $1.requests })
    }.sorted { $0.tokens > $1.tokens }
  }
  var body: some View {
    List {
      Section {
        Picker("Source", selection: $source) {
          Text("This device").tag("device")
          if model.credential != nil { Text("Central library").tag("central") }
        }
        DashboardSegmentedSelector(options: [1, 7, 30], selection: $days) { $0 == 1 ? "24 hours" : "\($0) days" }
          .accessibilityLabel("Usage time range")
      }.listRowBackground(Color.clear)
      if let failure { HomeDataError(message: failure) }
      if loading && !loaded { ProgressView("Loading usage…") }
      if !loaded && !loading && failure == nil { Text("No usage loaded.").foregroundStyle(DashboardPalette.mutedForeground) }
      if loaded {
        Section(hasMore ? "Loaded records" : "Recorded usage") {
          LabeledContent("Tokens") { Text(totalTokens, format: .number).monospacedDigit() }
          LabeledContent("Requests") { Text(samples.reduce(0) { $0 + $1.requests }, format: .number).monospacedDigit() }
          LabeledContent("Sessions") { Text(Set(samples.map(\.sessionID)).count, format: .number).monospacedDigit() }
          if samples.contains(where: { $0.costUSD != nil }) {
            LabeledContent("Recorded spend") {
              Text(samples.compactMap(\.costUSD).reduce(0, +), format: .currency(code: "USD")).monospacedDigit()
            }
          }
        }
        if !groups.isEmpty {
          Section("Models") {
            ForEach(groups, id: \.name) { group in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(group.name).font(.subheadline.weight(.medium))
                  Spacer()
                  Text(group.tokens, format: .number.notation(.compactName)).monospacedDigit()
                }
                GeometryReader { geometry in
                  Capsule().fill(DashboardPalette.primary.opacity(0.12)).overlay(alignment: .leading) {
                    Capsule().fill(DashboardPalette.primary)
                      .frame(width: geometry.size.width * min(1, Double(group.tokens) / Double(max(1, groups.first?.tokens ?? 1))))
                  }
                }.frame(height: 5).accessibilityHidden(true)
                Text("\(group.requests) requests").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
              }.padding(.vertical, 5)
            }
          }
        }
        Section("Activity") {
          ForEach(samples) { sample in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .firstTextBaseline) {
                Text(sample.model).font(.subheadline.weight(.medium))
                Spacer()
                Text(sample.totalTokens, format: .number.notation(.compactName)).font(.subheadline).monospacedDigit()
              }
              Text([sample.provider, sample.workspace].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
              Text(sample.timestamp, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            }.padding(.vertical, 3)
          }
          if samples.isEmpty { Text("No recorded usage in this period.").foregroundStyle(DashboardPalette.mutedForeground) }
          if hasMore {
            Button(loading ? "Loading…" : "Load more") { Task { await load(more: true) } }.disabled(loading || !model.online)
          }
        }
      }
    }
    .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.never)
    .navigationTitle("Usage").navigationBarTitleDisplayMode(.inline).mobilePageSurface().toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { Task { await load() } } label: { DashboardLucideIcon(glyph: .rotate, size: 20) }
          .disabled(!available || loading).accessibilityLabel("Refresh usage")
      }
    }
    .refreshable { await load() }
    .task(id: scope) {
      generation += 1; loading = false; samples = []; loaded = false; hasMore = false; failure = nil
      if source == "central", model.credential == nil { source = "device"; return }
      await load()
    }
  }
  private func load(more: Bool = false) async {
    guard available, !more || !loading else { return }
    generation += 1; let requestGeneration = generation
    let expected = scope; loading = true; failure = nil
    if !more { intervalEnd = Date(); offset = 0 }
    let requestedOffset = offset
    defer { if requestGeneration == generation { loading = false } }
    do {
      let start = intervalEnd.addingTimeInterval(-Double(days) * 86_400)
      let values: [CompanionUsageSample], next: Bool
      if source == "device" {
        guard let journal = await model.store?.journal.snapshot() else { throw MobileConnectionError.offline }
        let workspaceID = model.deviceWorkspaceID, end = intervalEnd
        values = try await Task.detached(priority: .userInitiated) {
          try DeviceUsageProjection.samples(in: journal, workspaceID: workspaceID, from: start, to: end)
        }.value
        next = false
      } else {
        guard case .usage(let page, let more) = try await model.workspace(.usage(from: start, to: intervalEnd, offset: requestedOffset)) else { throw MobileConnectionError.invalidResponse }
        values = page; next = more
      }
      guard expected == scope, requestGeneration == generation, !Task.isCancelled else { return }
      let previous = more ? samples : []
      let existing = Set(previous.map(\.id))
      samples = previous + values.filter { !existing.contains($0.id) }; offset = requestedOffset + values.count
      hasMore = next; loaded = true
    } catch { if expected == scope, requestGeneration == generation, !Task.isCancelled { failure = error.localizedDescription } }
  }
}

private struct HomeDataError: View {
  let message: String
  var body: some View { Text(message).font(.subheadline).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
}
