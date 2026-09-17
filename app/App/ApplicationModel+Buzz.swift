import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore


extension ApplicationModel {
    var buzzWorkspaceLinks: [BuzzWorkspaceLink] {
        buzzWorkspaceSnapshot.links
    }

    var buzzWorkspaceAgentEnrollments: [BuzzWorkspaceAgentEnrollment] {
        buzzWorkspaceSnapshot.enrollments
    }

    func isBuzzWorkspaceAgentLaunchable(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) -> Bool {
        launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id)
    }

    func setBuzzDiscoveryEnabled(_ enabled: Bool) {
        applicationDefaults.set(
            enabled,
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        )
        Task {
            if enabled {
                await refreshBuzzWorkspaces()
            } else {
                buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                    links: [],
                    enrollments: []
                )
                buzzWorkspaceCandidates.removeAll()
                launchableBuzzWorkspaceEnrollmentIDs.removeAll()
                buzzWorkspaceAgents = []
            }
            await refreshWorkspace()
        }
    }

    @discardableResult
    func addLocalBuzzWorkspace(
        displayName: String,
        workspacePath rawWorkspacePath: String,
        agentStorePath rawAgentStorePath: String
    ) async -> Bool {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            buzzWorkspaceError = "Enter a workspace name."
            return false
        }
        let workspaceURL = Self.expandedLocalFileURL(rawWorkspacePath)
        let storeURL = Self.expandedLocalFileURL(rawAgentStorePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspaceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            buzzWorkspaceError = "The selected Buzz workspace folder is unavailable."
            return false
        }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            buzzWorkspaceError = "The selected Buzz agent catalog is unavailable."
            return false
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let link = BuzzWorkspaceLink(
                displayName: cleanName,
                localWorkspaceURL: workspaceURL,
                localAgentStoreURL: storeURL
            )
            try await dashboardStore.saveBuzzWorkspace(link)
            buzzWorkspaceError = nil
            await refreshBuzzWorkspaces()
            await refreshWorkspace()
            return true
        } catch {
            buzzWorkspaceError = error.localizedDescription
            return false
        }
    }

    func discoverBuzzWorkspaceAgents(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        buzzWorkspaceError = nil
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                buzzWorkspaceCandidates[link.id] = try await dashboardStore
                    .discoverBuzzWorkspaceAgents(linkID: link.id)
            } catch {
                buzzWorkspaceCandidates[link.id] = []
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func enrollBuzzWorkspaceAgent(_ candidate: BuzzWorkspaceAgentCandidate) {
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let enrollment = try await dashboardStore
                    .enrollBuzzWorkspaceAgent(candidate)
                mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id)
                defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func removeBuzzWorkspaceAgentEnrollment(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) {
        guard mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id).inserted else {
            return
        }
        Task {
            defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.removeBuzzWorkspaceAgentEnrollment(
                    id: enrollment.id
                )
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func deleteBuzzWorkspace(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.deleteBuzzWorkspace(id: link.id)
                buzzWorkspaceCandidates.removeValue(forKey: link.id)
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func refreshBuzzWorkspaces() async {
        guard applicationDefaults.bool(
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        ) else {
            buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                links: [],
                enrollments: []
            )
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            return
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            launchableBuzzWorkspaceEnrollmentIDs = try await dashboardStore
                .reconcileBuzzWorkspaceAgents()
            buzzWorkspaceSnapshot = try await dashboardStore.buzzWorkspaceSnapshot()
            buzzBoundLocalACPConversationIDs = try await dashboardStore
                .buzzBoundLocalACPConversationIDs()
            buzzWorkspaceError = nil
        } catch {
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            buzzWorkspaceError = error.localizedDescription
        }
    }
}
