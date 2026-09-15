import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct DashboardCronSurface: View {
  @Bindable var model: ApplicationModel
  let onOpenConversation: (String) -> Void
  @State private var provider = "Hermes"
  var body: some View {
    VStack(spacing: 0) {
      DashboardSegmentedSelector(
        options: ["Hermes", "OpenClaw"],
        selection: $provider
      ) { $0 }
      .frame(width: 240)
      .padding(.top, 16)
      .accessibilityLabel("Agent")
      if provider == "Hermes" {
        HermesCronSurface(model: model, onOpenConversation: onOpenConversation)
      } else {
        OpenClawCronSurface(model: model, onOpenConversation: onOpenConversation)
      }
    }
  }
}

struct HermesCronSurface: View {
  @Bindable var model: ApplicationModel
  let onOpenConversation: (String) -> Void
  @State private var selectedAgent: UUID?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Cron Jobs").font(.system(size: 22, weight: .semibold))
        Spacer()
        Picker("Workspace", selection: $selectedAgent) {
          Text("All workspaces").tag(nil as UUID?)
          ForEach(model.hermesCronAgents) { Text($0.displayName).tag(Optional($0.id)) }
        }.frame(maxWidth: 200)
        Button(model.isRefreshingHermesCron ? "Refreshing…" : "Refresh") {
          Task { await model.refreshHermesCron() }
        }
        .buttonStyle(DashboardQuietButtonStyle()).disabled(model.isRefreshingHermesCron)
      }
      Text(
        "Jobs keep running while Woven Matter is closed, as long as Hermes and its host stay running."
      )
      .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if model.hermesCronAgents.isEmpty {
            Text("Connect Hermes in Settings to schedule jobs.")
          }
          ForEach(model.hermesCronAgents.filter { selectedAgent == nil || $0.id == selectedAgent })
          { agent in
            VStack(alignment: .leading, spacing: 12) {
              Text(agent.displayName).font(.headline)
              Text(
                agent.runtimeDeviceID.flatMap { model.remoteWorkspaces.configuration(id: $0)?.name }
                  ?? "This Mac"
              )
              .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
              if let error = model.hermesCronErrors[agent.id] { SettingsError(error) }
              HermesCronJobForm(model: model, agent: agent)
              Text("If another Hermes Gateway runs these jobs, restart it after first enabling result delivery.")
                .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
              if (model.hermesCronJobs[agent.id] ?? []).isEmpty {
                Text("No scheduled jobs.").font(.callout)
              }
              ForEach((model.hermesCronJobs[agent.id] ?? []).map { (id: $0["id"].text, value: $0) }, id: \.id) { job in
                jobCard(agent: agent, job: job.value)
              }
              DisclosureGroup("Retained results") {
                ForEach((model.hermesCronResults[agent.id] ?? []).reversed()) { result in
                  DisclosureGroup(
                    result.jobID + " · "
                      + Date(timeIntervalSince1970: result.savedAt).formatted(
                        date: .abbreviated, time: .shortened)
                  ) {
                    VStack(alignment: .leading, spacing: 8) {
                      Text(result.output).font(.system(size: 12)).textSelection(.enabled)
                      Button("Continue in chat") {
                        Task {
                          if let id = await model.continueHermesResult(agent: agent, result: result)
                          {
                            onOpenConversation(id)
                          }
                        }
                      }.buttonStyle(DashboardQuietButtonStyle())
                      Text("Opens an unsent draft for review.").font(.caption)
                    }
                  }
                }
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(32).task { await model.refreshHermesCron() }
  }

  private func jobCard(agent: WorkspaceAgent, job: HermesValue) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(job["name"].string ?? job["id"].text).font(.system(size: 14, weight: .semibold))
          Text(job["schedule"].string ?? job["schedule"].json).font(.caption).foregroundStyle(
            DashboardPalette.mutedForeground)
        }
        Spacer()
        Button(job["enabled"].bool ? "Pause" : "Resume") {
          Task {
            await model.changeHermesCron(
              agent: agent, jobID: job["id"].text, action: job["enabled"].bool ? "pause" : "resume")
          }
        }.buttonStyle(DashboardQuietButtonStyle())
      }
      Picker(
        "Send results to",
        selection: Binding(
          get: { model.hermesResultRoutes[agent.id]?[job["id"].text] ?? "" },
          set: { destination in
            Task {
              await model.setHermesResultRoute(
                agent: agent, jobID: job["id"].text, destination: destination)
            }
          }
        )
      ) {
        Text("Cron Jobs only").tag("")
        Text("New chat for each result").tag("new")
        ForEach(
          (model.workspaceOverview?.conversations ?? []).filter {
            $0.agentID == agent.id.uuidString.lowercased() && !$0.isArchived
          }
        ) { conversation in
          Text(conversation.title).tag(conversation.id)
        }
      }
      if let error = job["last_delivery_error"].string, !error.isEmpty { SettingsError(error) }
      DisclosureGroup("Job details") {
        Text(job["prompt"].string ?? job["script"].string ?? "No prompt").font(.callout)
          .textSelection(.enabled)
      }
    }.padding(16).background(DashboardPalette.background).clipShape(
      RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
  }
}

private struct HermesCronJobForm: View {
  @Bindable var model: ApplicationModel
  let agent: WorkspaceAgent
  @State private var name = ""
  @State private var schedule = ""
  @State private var prompt = ""
  @State private var creating = false

  var body: some View {
    DisclosureGroup("New scheduled job") {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Name", text: $name)
        TextField("Schedule, e.g. every 1h", text: $schedule)
        TextField("Instructions", text: $prompt, axis: .vertical).lineLimit(3...8)
        Button("Create paused job") {
          creating = true
          Task {
            if await model.createHermesCron(
              agent: agent, name: name, schedule: schedule, prompt: prompt)
            {
              name = ""
              schedule = ""
              prompt = ""
            }
            creating = false
          }
        }.disabled(
          creating || schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Text("Choose where to send results, then resume the job.").font(
          .caption)
      }.textFieldStyle(.roundedBorder)
    }
  }
}
