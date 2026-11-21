import SwiftUI

struct CalendarTaskFields: View {
    @Bindable var model: ApplicationModel
    @Binding var task: CalendarTask
    /// The machine that runs the task. Nil means this Mac.
    @Binding var machineID: String?
    let recurring: Bool
    @State private var metadata: SessionSettings?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var error: String?

    static func machineName(_ id: String?, in model: ApplicationModel) -> String {
        guard let id = id ?? model.thisMachineID else { return "This Mac" }
        return model.machines.machine(id: id)?.name ?? "Unavailable machine"
    }

    private var catalogKey: String {
        [task.configuration.runtimeKind.rawValue, machineID ?? "",
         task.configuration.workingDirectory ?? "", task.configuration.model ?? ""].joined(separator: "|")
    }
    private func choice(_ key: WritableKeyPath<CalendarTaskConfiguration, String?>) -> Binding<String> {
        Binding(get: { task.configuration[keyPath: key] ?? "" }, set: { value in
            task.configuration[keyPath: key] = value.isEmpty ? nil : value
            if key == \.model { task.configuration.thinking = nil }
        })
    }
    private var machine: Binding<String> {
        Binding(get: { machineID ?? model.thisMachineID ?? "" }, set: { id in
            machineID = id.isEmpty ? nil : id
            changeAgent(task.configuration.runtimeKind)
            task.configuration.folderID = nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Session").font(.system(size: 14, weight: .semibold))
            CalendarField("Work location") {
                CalendarMenuPicker(title: "Work location", selection: machine, options: machineOptions) { id in
                    Self.machineName(id.isEmpty ? nil : id, in: model)
                }
            }
            CalendarField("Agent") {
                CalendarMenuPicker(title: "Agent", selection: Binding(get: { task.configuration.runtimeKind }, set: {
                    changeAgent($0)
                }), options: AgentRuntimeKind.presentationOrder, label: { $0.displayName })
            }
            CalendarField("Session folder") {
                CalendarMenuPicker(title: "Session folder", selection: choice(\.folderID), options: folderOptions, label: folderName)
            }
            CalendarField("Working directory") {
                TextField("Working directory", text: choice(\.workingDirectory))
                    .modifier(CalendarInputStyle())
            }
            HStack {
                Text("Session settings").font(.system(size: 12, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { refreshID += 1 }.buttonStyle(WovenQuietButtonStyle()).disabled(loading)
            }
            optionPicker("Model", selection: choice(\.model), choices: metadata?.selectableModels ?? [], metadata: metadata?.modelOptionMetadata ?? [:])
            optionPicker("Thinking level", selection: choice(\.thinking), choices: metadata?.selectableThinkingLevels ?? [], metadata: metadata?.thinkingOptionMetadata ?? [:])
            optionPicker("Access", selection: choice(\.permission), choices: metadata?.permissionOptions ?? [], metadata: metadata?.permissionOptionMetadata ?? [:])
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(WovenPalette.danger).fixedSize(horizontal: false, vertical: true) }
            if recurring {
                CalendarField("Send each occurrence to") {
                    CalendarMenuPicker(title: "Send each occurrence to", selection: $task.sessionMode,
                        options: CalendarTask.SessionMode.allCases, label: { $0.title })
                }
            }
            CalendarField("Prompt") {
                TextEditor(text: $task.prompt)
                    .scrollContentBackground(.hidden).scrollIndicators(.never)
                    .frame(height: 120)
                    .modifier(CalendarInputStyle())
                    .accessibilityLabel("Scheduled task prompt")
            }
        }
        .font(.system(size: 12.5))
        .task(id: catalogKey + "|" + String(refreshID)) { await loadMetadata() }
    }

    private func folderName(_ id: String) -> String {
        guard !id.isEmpty else { return "All Workspaces" }
        let folder = model.workspace.workspaceOverview?.folders.first { $0.id == id }
        return folder?.name ?? "Unavailable folder"
    }

    private var machineOptions: [String] {
        var options = model.machines.machines.map(\.id)
        if !options.contains(machine.wrappedValue) { options.append(machine.wrappedValue) }
        return options
    }

    /// Folders belong to one machine, so only the running machine's folders are offered.
    private var folderOptions: [String] {
        let runningMachine = machineID ?? model.thisMachineID
        let folders = model.workspace.workspaceOverview?.folders.filter { $0.machineID == runningMachine } ?? []
        var options = [""] + folders.map(\.id)
        if let id = task.configuration.folderID, !options.contains(id) { options.append(id) }
        return options
    }

    private func optionPicker(_ title: String, selection: Binding<String>, choices: [String], metadata: [String: SessionOptionMetadata]) -> some View {
        let options = [""] + choices + (selection.wrappedValue.isEmpty || choices.contains(selection.wrappedValue) ? [] : [selection.wrappedValue])
        return CalendarField(title) {
            CalendarMenuPicker(title: title, selection: selection, options: options) {
                $0.isEmpty ? "Agent default" : metadata[$0]?.name ?? $0
            }
        }.disabled(loading)
    }

    private func changeAgent(_ runtime: AgentRuntimeKind) {
        let current = task
        task = model.calendar.taskDefaults(runtime: runtime, title: current.configuration.title)
        task.prompt = current.prompt; task.sessionMode = current.sessionMode
        task.configuration.folderID = current.configuration.folderID
        metadata = nil; error = nil
    }

    private func loadMetadata() async {
        let key = catalogKey
        loading = true; error = nil; metadata = nil
        defer { if !Task.isCancelled, key == catalogKey { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(400))
            let value = try await model.calendar.taskOptions(for: task, machineID: machineID)
            guard !Task.isCancelled, key == catalogKey else { return }
            metadata = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled, key == catalogKey { self.error = error.localizedDescription } }
    }
}
