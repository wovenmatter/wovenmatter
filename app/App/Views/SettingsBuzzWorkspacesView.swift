import SwiftUI
import WovenMatterCore

struct SettingsBuzzWorkspacesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @AppStorage("wovenmatter.buzz.discovery-enabled")
    private var discoveryEnabled = false
    @State private var workspaceName = "Local Buzz workspace"
    @State private var workspacePath = "~/.buzz"
    @State private var agentCatalogPath = ""

    var body: some View {
        SettingsPage(
            title: "Buzz Agent Workspaces",
            detail: "Optionally discover agents from Buzz data already stored on this Mac.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsCard(
                title: "Local discovery",
                detail: "Disabled by default. Woven Matter reads only the workspace and agent catalog paths you add below."
            ) {
                Toggle("Enable local Buzz discovery", isOn: $discoveryEnabled)
                    .toggleStyle(.switch)
                SettingsNote("No cloud service or relay is contacted by this feature.")
            }

            if discoveryEnabled {
                linkedWorkspaces
                addWorkspace
            } else {
                SettingsEmpty("Enable local discovery to add a Buzz workspace on this Mac.")
            }

            if let error = model.buzzWorkspaceError {
                SettingsError(error)
            }
        }
        .onChange(of: discoveryEnabled) { _, enabled in
            model.setBuzzDiscoveryEnabled(enabled)
        }
    }

    private var linkedWorkspaces: some View {
        SettingsCard(
            title: "Linked local workspaces",
            detail: "Discovery is explicit. Candidates are not enrolled until you choose Add."
        ) {
            if model.buzzWorkspaceLinks.isEmpty {
                SettingsEmpty("No local Buzz workspaces are linked yet.")
            } else {
                ForEach(model.buzzWorkspaceLinks) { link in
                    workspaceRow(link)
                }
            }
        }
    }

    private func workspaceRow(_ link: BuzzWorkspaceLink) -> some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(link.localWorkspaceURL.path)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Discover") {
                        model.discoverBuzzWorkspaceAgents(link)
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.checkingBuzzWorkspaceLinkIDs.contains(link.id))
                    Button("Remove", role: .destructive) {
                        model.deleteBuzzWorkspace(link)
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.checkingBuzzWorkspaceLinkIDs.contains(link.id))
                }

                if let candidates = model.buzzWorkspaceCandidates[link.id] {
                    if candidates.isEmpty {
                        SettingsEmpty("No supported agents were found in this catalog.")
                    } else {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }

                let enrollments = model.buzzWorkspaceAgentEnrollments.filter {
                    $0.workspaceLinkID == link.id
                }
                ForEach(enrollments) { enrollment in
                    HStack {
                        Text(enrollment.displayNameSnapshot)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        SettingsPill("Enrolled", tone: .neutral)
                        Button("Remove") {
                            model.removeBuzzWorkspaceAgentEnrollment(enrollment)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(
                            model.mutatingBuzzWorkspaceEnrollmentIDs.contains(enrollment.id)
                        )
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: BuzzWorkspaceAgentCandidate) -> some View {
        let enrolled = model.buzzWorkspaceAgentEnrollments.contains {
            $0.workspaceLinkID == candidate.workspaceLinkID
                && $0.agentID == candidate.agentID
        }
        return HStack {
            DashboardHarnessLogoIcon(
                logo: DashboardHarnessLogo.resolve(
                    harnessIdentifier: candidate.harnessIdentifier,
                    runtimeKind: candidate.runtimeKind
                ) ?? .openClaw,
                size: 16
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(candidate.runtimeKind?.displayName ?? candidate.harnessIdentifier)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            Button(enrolled ? "Added" : "Add") {
                model.enrollBuzzWorkspaceAgent(candidate)
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(enrolled)
        }
    }

    private var addWorkspace: some View {
        SettingsCard(
            title: "Add a local workspace",
            detail: "Choose the local workspace folder and Buzz agent catalog. Both remain on this Mac."
        ) {
            SettingsField("Name") {
                TextField("Local Buzz workspace", text: $workspaceName)
                    .settingsInput()
            }
            SettingsField("Workspace folder") {
                TextField("~/.buzz", text: $workspacePath)
                    .settingsInput()
            }
            SettingsField("Agent catalog JSON") {
                TextField("/path/to/agents.json", text: $agentCatalogPath)
                    .settingsInput()
            }
            Button("Add Local Workspace") {
                Task {
                    if await model.addLocalBuzzWorkspace(
                        displayName: workspaceName,
                        workspacePath: workspacePath,
                        agentStorePath: agentCatalogPath
                    ) {
                        agentCatalogPath = ""
                    }
                }
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
        }
    }
}
