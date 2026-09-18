import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func dismissPendingHermesSettings() { pendingHermesSettingsAgentID = nil }

    func requireLocalHermesLink(conversationID: String? = nil, openSettings: Bool = false) throws {
        guard let agent = localCLIAgents.first(where: { $0.runtimeKind == .hermes }) else {
            throw HermesGatewayError.message("Enable Hermes in Local agent workspace first.")
        }
        guard isHermesGatewayLinked(agentID: agent.id) else {
            if openSettings { pendingHermesSettingsAgentID = agent.id }
            throw HermesGatewayError.message("Connect this Hermes agent's Gateway in Settings before starting or continuing a chat.")
        }
        if let conversationID,
           let stored = try dashboardStore?.database.localACPSession(conversationID: conversationID).acpSessionID,
           let home = HermesGatewayClient.parseIdentity(stored).home,
           home != applicationDefaults.string(forKey: "hermes.gateway.link." + agent.id.uuidString) {
            throw HermesGatewayError.message("This chat belongs to another Hermes profile. Select and connect that profile before continuing.")
        }
    }

    func isHermesGatewayLinked(agentID: UUID) -> Bool {
        guard enabledLocalACPRuntimeKinds.contains(.hermes),
              let launch = localACPLaunchConfigurations[.hermes] else { return false }
        let home = launch.environment["HERMES_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes").path
        return applicationDefaults.string(forKey: "hermes.gateway.link." + agentID.uuidString) == home
    }

    func connectHermesGateway(agentID: UUID, restart: Bool = false) async throws {
        guard localCLIAgents.contains(where: { $0.id == agentID && $0.runtimeKind == .hermes }) else {
            throw HermesGatewayError.message("This Hermes agent is no longer available.")
        }
        hermesGatewayConnections[agentID] = nil
        let connected: HermesGatewayConnection
        if restart {
            let current = try await hermesGatewayConnection()
            try await HermesGatewayService.shared.stopIfIdle(home: current.home)
        }
        connected = try await hermesGatewayConnection()
        let client = HermesGatewayRPC(connection: connected)
        do {
            try await client.connect()
            let setup = try await client.call("setup.runtime_check")
            guard setup["ok"].bool else {
                throw HermesGatewayError.message("Hermes needs provider setup. Run hermes model for this profile, then reconnect.")
            }
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
        hermesGatewayConnections[agentID] = connected
        hermesGatewayCheckedAt[agentID] = Date()
        localRunError = nil
        applicationDefaults.set(connected.home, forKey: "hermes.gateway.link." + agentID.uuidString)
    }

    func invalidateHermesGatewayConnection(agentID: UUID, expected: HermesGatewayConnection) {
        guard hermesGatewayConnections[agentID] == expected else { return }
        hermesGatewayConnections[agentID] = nil
    }

    func unlinkHermesGateway(agentID: UUID) {
        hermesGatewayConnections[agentID] = nil
        hermesGatewayCheckedAt[agentID] = nil
        applicationDefaults.removeObject(forKey: "hermes.gateway.link." + agentID.uuidString)
    }

    func renameHermesAgent(agentID: UUID, displayName: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try dashboardStore.database.renameHermesAgent(id: agentID, displayName: displayName)
        await refreshWorkspace()
    }

    var hermesCronAgents: [WorkspaceAgent] {
        localCLIAgents.filter { $0.runtimeKind == .hermes && isHermesGatewayLinked(agentID:$0.id) }
          + remoteWorkspaceAgents.filter { agent in
              agent.runtimeKind == .hermes && agent.runtimeDeviceID.map { applicationDefaults.bool(forKey:"hermes.remote.link." + $0.uuidString) } == true
          }
    }

    private func cronHermesConnection(agent: WorkspaceAgent) async throws -> HermesGatewayConnection {
        if let workspaceID = agent.runtimeDeviceID, let configuration = remoteWorkspaces.configuration(id:workspaceID) {
            let connection = try await remoteWorkspaces.prepareHermesConnection(for:configuration)
            remoteHermesConnections[workspaceID] = connection
            return connection
        }
        guard isHermesGatewayLinked(agentID:agent.id) else { throw HermesGatewayError.message("Connect Hermes in Settings first.") }
        return try await hermesGatewayConnection()
    }

    func refreshHermesCron() async {
        guard !isRefreshingHermesCron, let dashboardStore else { return }
        isRefreshingHermesCron = true
        lastHermesCronRefresh = Date()
        defer { isRefreshingHermesCron = false }
        for agent in hermesCronAgents {
            do {
                let connection = try await cronHermesConnection(agent:agent)
                let query = try await HermesDelivery.profileQuery(connection:connection)
                let document = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs" + query)
                guard case .array(let jobs) = document, jobs.allSatisfy({!$0["id"].text.isEmpty}) else {
                    throw HermesGatewayError.message("Hermes returned an incomplete scheduled-job list.")
                }
                hermesCronJobs[agent.id] = jobs
                let sourcePrefix=connection.identity + "::"
                hermesResultRoutes[agent.id] = Dictionary(uniqueKeysWithValues: try dashboardStore.database.hermesResultRoutes(agentID:agent.id).filter{$0.key.hasPrefix(sourcePrefix)}.map{(String($0.key.dropFirst(sourcePrefix.count)),$0.value)})
                let owner = try await dashboardStore.dashboardDeviceID()
                var offset = 0
                var all:[HermesScheduledResult] = []
                var collectionError: String?
                while true {
                    try Task.checkCancellation()
                    let page:[HermesScheduledResult]
                    if let workspaceID=connection.remoteWorkspaceID, let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                        page = try await remoteWorkspaces.hermesResults(for:configuration,offset:offset)
                    } else {
                        page = try HermesResultQueue.read(home:connection.home,offset:offset)
                    }
                    guard hermesCronAgents.contains(where:{$0.id == agent.id}) else { throw CancellationError() }
                    for result in page {
                      do {
                        _ = try dashboardStore.database.collectHermesResult(agentID:agent.id,jobID:connection.identity + "::" + result.jobID,runID:result.runID,
                            title:jobs.first(where:{$0["id"].text == result.jobID})?["name"].string ?? "Hermes scheduled result",output:result.output,
                            ownerDeviceID:owner,remoteWorkspaceID:connection.remoteWorkspaceID,
                            remoteWorkspaceName:connection.remoteWorkspaceID.flatMap{remoteWorkspaces.configuration(id:$0)?.name} ?? "")
                      } catch { collectionError = collectionError ?? error.localizedDescription }
                    }
                    all.append(contentsOf:page)
                    if page.count < 100 { break }
                    offset += page.count
                }
                hermesCronResults[agent.id] = all
                hermesCronErrors[agent.id] = collectionError
            } catch { hermesCronErrors[agent.id] = error.localizedDescription }
        }
    }

    func continueHermesResult(agent:WorkspaceAgent,result:HermesScheduledResult) async -> String? {
        guard let dashboardStore else { return nil }
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let existing=try dashboardStore.database.hermesResultConversation(agentID:agent.id,jobID:connection.identity + "::" + result.jobID,runID:result.runID)
            let id:String
            if let existing { id=existing }
            else if let workspaceID=connection.remoteWorkspaceID,let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                id=try await dashboardStore.createRemoteACPSession(runtimeKind:.hermes,remoteWorkspaceID:workspaceID,remoteWorkspaceName:configuration.name,title:"Hermes scheduled result")
            } else {
                guard let created=await createLocalACPSession(runtimeKind:.hermes) else { return nil }
                id=created
            }
            pendingComposerPrefills[id]="Discuss this scheduled result.\n\n" + result.output
            await refreshWorkspace()
            return id
        } catch { hermesCronErrors[agent.id]=error.localizedDescription;return nil }
    }

    private func hermesDeliveryTargets(agentID:UUID,jobID:String) -> String {
        let current=hermesCronJobs[agentID]?.first(where:{$0["id"].text == jobID})?["deliver"].string ?? "local"
        var targets=current.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty && $0 != "local" && !$0.hasPrefix("wovenmatter:")}
        targets.append("wovenmatter:" + jobID)
        return targets.joined(separator:",")
    }

    func createHermesCron(agent:WorkspaceAgent,name:String,schedule:String,prompt:String) async -> Bool {
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let job = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs" + (try await HermesDelivery.profileQuery(connection:connection)),method:"POST",
                body:["name":.string(name),"schedule":.string(schedule),"prompt":.string(prompt),"paused":.bool(true),"deliver":"local"])
            guard let jobID = job["id"].string, !jobID.isEmpty else { throw HermesGatewayError.message("Hermes created no identifiable scheduled job.") }
            await refreshHermesCron()
            await setHermesResultRoute(agent: agent, jobID: jobID, destination: "")
            return true
        } catch { hermesCronErrors[agent.id]=error.localizedDescription;return false }
    }

    func setHermesResultRoute(agent:WorkspaceAgent, jobID:String, destination:String) async {
        guard let dashboardStore else { return }
        do {
            var connection = try await cronHermesConnection(agent:agent)
            let needsRestart = try await HermesDelivery.enable(connection:connection)
            if needsRestart, let workspaceID=connection.remoteWorkspaceID, let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                try await remoteWorkspaces.restartHermes(for:configuration)
            } else if needsRestart { try await HermesGatewayService.shared.stopIfIdle(home:connection.home) }
            connection = try await cronHermesConnection(agent:agent)
            let id = jobID.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            _ = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs/" + id + (try await HermesDelivery.profileQuery(connection:connection)),method:"PUT",
                body:["updates":["deliver":.string(hermesDeliveryTargets(agentID:agent.id,jobID:jobID))]])
            try dashboardStore.database.setHermesResultRoute(agentID:agent.id,jobID:connection.identity + "::" + jobID,destination:destination)
            await refreshHermesCron()
            await refreshWorkspace()
        } catch { hermesCronErrors[agent.id] = error.localizedDescription }
    }

    func changeHermesCron(agent:WorkspaceAgent,jobID:String,action:String) async {
        guard ["pause","resume"].contains(action) else { return }
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let id=jobID.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            _ = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs/"+id+"/"+action + (try await HermesDelivery.profileQuery(connection:connection)),method:"POST")
            await refreshHermesCron()
        } catch { hermesCronErrors[agent.id]=error.localizedDescription }
    }

    func stopRemoteHermes(_ configuration:RemoteWorkspaceConfiguration) async throws {
        applicationDefaults.set(false,forKey:"hermes.remote.link." + configuration.id.uuidString)
        do { try await remoteWorkspaces.restartHermes(for:configuration,action:"stop") }
        catch { applicationDefaults.set(true,forKey:"hermes.remote.link." + configuration.id.uuidString);throw error }
        remoteHermesConnections[configuration.id]=nil
        remoteWorkspaces.refresh(configuration)
    }

    func connectRemoteHermes(_ configuration: RemoteWorkspaceConfiguration) async throws {
        let connection = try await remoteWorkspaces.prepareHermesConnection(for: configuration)
        let rpc = HermesGatewayRPC(connection: connection)
        do { try await rpc.connect(); await rpc.disconnect() }
        catch { await rpc.disconnect(); throw error }
        guard remoteWorkspaces.configuration(id: configuration.id) == configuration else { throw CancellationError() }
        remoteHermesConnections[configuration.id] = connection
        applicationDefaults.set(true, forKey:"hermes.remote.link." + configuration.id.uuidString)
        remoteWorkspaces.refresh(configuration)
    }

    func hermesGatewayConnection() async throws -> HermesGatewayConnection {
        guard enabledLocalACPRuntimeKinds.contains(.hermes), let launch = localACPLaunchConfigurations[.hermes] else {
            throw HermesGatewayError.message("Enable Hermes in Local agent workspace, then refresh this page.")
        }
        return try await HermesGatewayService.shared.ensure(launch: launch)
    }

    func knownHermesSessions(home: String) throws -> Set<String> {
        try dashboardStore?.database.knownHermesSessionIDs(home: home) ?? []
    }

    func importHermesSession(connection: HermesGatewayConnection, sessionID: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try requireLocalHermesLink()
        guard localCLIAgents.contains(where: { $0.runtimeKind == .hermes && hermesGatewayConnections[$0.id] == connection }) else {
            throw HermesGatewayError.message("The Hermes connection changed. Reconnect before importing.")
        }
        guard try !dashboardStore.database.knownHermesSessionIDs(home: connection.home).contains(sessionID) else { return }
        let snapshot = try await HermesSessionHistory.load(connection: connection, sessionID: sessionID)
        let owner = try await dashboardStore.dashboardDeviceID()
        _ = try dashboardStore.database.createLocalACPSession(runtimeKind: .hermes, title: snapshot.title,
            ownerDeviceID: owner, createdAt: snapshot.createdAt, hermesImport: snapshot)
        await refreshWorkspace()
    }
}
