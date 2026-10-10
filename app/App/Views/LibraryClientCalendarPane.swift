import SwiftUI
import CompanionClient
import WovenMatterCompanion

struct LibraryClientCalendarPane: View {
  @Bindable var model: CentralLibraryClientModel
  @State private var month = Date()
  @State private var events: [CompanionCalendarEvent] = []
  @State private var selected: CompanionCalendarEvent?
  @State private var creating = false
  @State private var loading = false
  @State private var loadGeneration = 0
  @State private var failure: String?
  var body: some View {
    VStack(spacing: 0) {
      LibraryClientPaneHeader(title: "Calendar") {
        Button { creating = true } label: { DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }.disabled(!model.online).accessibilityLabel("New calendar event")
      }
      HStack {
        Button { shift(-1) } label: { DashboardLucideIcon(glyph: .arrowLeft, size: 20).frame(width: 44, height: 44) }.accessibilityLabel("Previous month")
        Spacer()
        Text(month, format: .dateTime.month(.wide).year()).font(.headline)
        Spacer()
        Button { shift(1) } label: { DashboardLucideIcon(glyph: .arrowRight, size: 20).frame(width: 44, height: 44) }.accessibilityLabel("Next month")
      }.buttonStyle(DashboardIconButtonStyle()).padding(.horizontal, 24).padding(.bottom)
      List {
        if !model.online { Text("Connect to your central Mac to view Calendar and scheduled tasks.").foregroundStyle(DashboardPalette.mutedForeground) }
        if loading { ProgressView() }
        if let failure { Text(failure).foregroundStyle(DashboardPalette.mutedForeground) }
        ForEach(events, id: \.occurrenceID) { event in
          Button { selected = event } label: {
            VStack(alignment: .leading, spacing: 6) {
              Label {
                Text(event.draft.title)
              } icon: {
                DashboardLucideIcon(glyph: event.draft.task == nil ? .calendarDays : .calendarClock, size: 20)
                  .foregroundStyle(eventColor(event))
              }
              Text(event.startsAt, format: event.draft.allDay ? .dateTime.weekday().month().day() : .dateTime.weekday().month().day().hour().minute()).font(.subheadline).foregroundStyle(DashboardPalette.mutedForeground)
              if let status = event.status { Text(status).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            }.padding(.vertical, 4)
          }.buttonStyle(.plain)
        }
        if model.online && events.isEmpty && !loading && failure == nil { Text("No events this month.").foregroundStyle(DashboardPalette.mutedForeground) }
      }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await load() }
    }.task(id: month) { await load() }.onChange(of: model.online) { Task { await load() } }
      .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
        LibraryClientCalendarEventSheet(model: model, event: nil).frame(minWidth: 520, minHeight: 550)
      }
      .sheet(item: $selected, onDismiss: { Task { await load() } }) { event in
        LibraryClientCalendarEventSheet(model: model, event: event).frame(minWidth: 520, minHeight: 550)
      }
  }
  private func eventColor(_ event: CompanionCalendarEvent) -> Color {
    if event.draft.task != nil {
      return event.draft.recurrenceUnit == nil ? DashboardPalette.calendarTask : DashboardPalette.calendarRecurringTask
    }
    return event.draft.recurrenceUnit == nil ? DashboardPalette.calendarEvent : DashboardPalette.calendarRecurringEvent
  }
  private func shift(_ step: Int) { month = Calendar.current.date(byAdding: .month, value: step, to: month) ?? month }
  private func load() async {
    guard model.online, let interval = Calendar.current.dateInterval(of: .month, for: month) else { return }
    loadGeneration += 1; let generation = loadGeneration
    loading = true; failure = nil
    defer { if generation == loadGeneration { loading = false } }
    do {
      guard case .calendar(let values) = try await model.workspace(.calendar(from: interval.start, to: interval.end)) else { throw MobileConnectionError.invalidResponse }
      if !Task.isCancelled, generation == loadGeneration { events = values }
    } catch { if !Task.isCancelled, generation == loadGeneration { failure = error.localizedDescription } }
  }
}

struct LibraryClientCalendarEventSheet: View {
  @Bindable var model: CentralLibraryClientModel
  let event: CompanionCalendarEvent?
  @State private var draft: CompanionCalendarDraft
  @State private var eventID: String
  @State private var busy = false
  @State private var confirmDelete = false
  @Environment(\.dismiss) private var dismiss
  init(model: CentralLibraryClientModel, event: CompanionCalendarEvent?) {
    self.model = model; self.event = event
    _draft = State(initialValue: event?.draft ?? .init(startsAt: Date().addingTimeInterval(3_600)))
    _eventID = State(initialValue: event?.id ?? UUID().uuidString.lowercased())
  }
  private var recurrence: Binding<String> { Binding(get: { draft.recurrenceUnit ?? "" }, set: { draft.recurrenceUnit = $0.isEmpty ? nil : $0 }) }
  private var scheduled: Binding<Bool> { Binding(get: { draft.task != nil }, set: { draft.task = $0 ? .init() : nil }) }
  var body: some View {
    NavigationStack {
      Form {
        if let error = model.errorMessage { Text(error).foregroundStyle(DashboardPalette.danger).accessibilityIdentifier("workspace-action-error") }
        if busy { ProgressView("Saving…") }
        Section("Event") {
          TextField("Title", text: $draft.title)
          TextField("Details", text: $draft.details, axis: .vertical).lineLimit(3...8)
          Toggle("All day", isOn: $draft.allDay)
          DatePicker("Starts", selection: $draft.startsAt, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
          Toggle("End time", isOn: Binding(get: { draft.endsAt != nil }, set: { draft.endsAt = $0 ? draft.startsAt.addingTimeInterval(3_600) : nil }))
          if draft.endsAt != nil {
            DatePicker("Ends", selection: Binding(get: { draft.endsAt ?? draft.startsAt }, set: { draft.endsAt = $0 }), displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
          }
          Text("Time zone: \(draft.timeZoneID)").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
          Picker("Repeat", selection: recurrence) {
            Text("Never").tag(""); Text("Daily").tag("day"); Text("Weekly").tag("week"); Text("Monthly").tag("month")
          }
          if draft.recurrenceUnit != nil { Stepper("Every \(draft.recurrenceInterval)", value: $draft.recurrenceInterval, in: 1...366) }
          if event?.draft.recurrenceUnit != nil { Text("Changes apply to the series. The start above is the series’ original start.").font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
        }
        Section("Scheduled task") {
          Toggle("Send a prompt to an agent", isOn: scheduled)
          if draft.task != nil { taskFields }
        }
        if let event {
          if let status = event.status { Section("Last run") { Text(status) } }
          if let id = event.sessionID {
            Button("Open task conversation") { dismiss(); Task { await model.selectConversation(id) } }
          }
          Section { Button("Delete event", role: .destructive) { confirmDelete = true } }
        }
      }.environment(\.timeZone, TimeZone(identifier: draft.timeZoneID) ?? .current)
        .disabled(busy || !model.online)
        .navigationTitle(event == nil ? "New event" : "Edit event")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
          ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy || !model.online || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .confirmationDialog("Delete this calendar event?", isPresented: $confirmDelete, titleVisibility: .visible) {
          if let event {
            if event.draft.recurrenceUnit != nil { Button("Delete this occurrence", role: .destructive) { Task { await delete(occurrence: event.occurrence) } } }
            Button(event.draft.recurrenceUnit == nil ? "Delete event" : "Delete entire series", role: .destructive) { Task { await delete(occurrence: nil) } }
          }
        }
    }
  }
  @ViewBuilder private var taskFields: some View {
    if let task = draft.task {
      Picker("Agent and workspace", selection: Binding(get: { selectedRoute }, set: { selectRoute($0) })) {
        ForEach(routeChoices) { Text($0.label).tag($0.id) }
      }
      if task.workspaceID != nil { Text("Runs in the remote workspace configured on your central Mac.").font(.caption) }
      TextField("Prompt", text: Binding(get: { draft.task?.prompt ?? "" }, set: { draft.task?.prompt = $0 }), axis: .vertical).lineLimit(4...12)
      Picker("Session folder", selection: Binding(get: { draft.task?.folderID ?? "" }, set: { draft.task?.folderID = $0.isEmpty ? nil : $0 })) {
        Text("No folder").tag("")
        ForEach(model.folders) { Text($0.name).tag($0.id) }
      }
      if draft.recurrenceUnit != nil { Toggle("New session each time", isOn: Binding(get: { draft.task?.newSessionEachTime ?? false }, set: { draft.task?.newSessionEachTime = $0 })) }
      Text("Runs on your central Mac using its saved agent settings. Keep the central Mac and its background service available at the scheduled time.").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
    }
  }
  private var selectedRoute: String {
    guard let task = draft.task else { return "local:default_agent" }
    return task.workspaceID.map { "remote:\($0):\(task.runtime)" } ?? "local:\(task.runtime)"
  }
  private var routeChoices: [CompanionSelection] {
    var values = model.providers.filter { $0.id.hasPrefix("local:") || $0.id.hasPrefix("remote:") }
      .map { CompanionSelection(id: $0.id, label: "\($0.displayName) · \($0.routeName)") }
    if !values.contains(where: { $0.id == selectedRoute }) {
      values.append(.init(id: selectedRoute, label: "Saved agent and workspace"))
    }
    return values
  }
  private func selectRoute(_ id: String) {
    guard let provider = model.providers.first(where: { $0.id == id }) else { return }
    draft.task?.runtime = provider.runtimeKind
    draft.task?.workspaceID = id.hasPrefix("remote:") ? String(id.split(separator: ":")[1]) : nil
    draft.task?.model = nil; draft.task?.thinking = nil; draft.task?.permission = nil
  }
  private func save() async {
    busy = true; defer { busy = false }
    if await model.perform(.saveCalendar(id: eventID, revision: event?.revision, draft: draft)) { dismiss() }
  }
  private func delete(occurrence: Int?) async {
    guard let event else { return }; busy = true; defer { busy = false }
    if await model.perform(.deleteCalendar(id: event.id, revision: event.revision, occurrence: occurrence)) { dismiss() }
  }
}
