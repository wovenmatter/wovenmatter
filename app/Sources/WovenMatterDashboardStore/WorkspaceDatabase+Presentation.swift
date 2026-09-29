import Foundation
import WovenMatterClient
import WovenMatterCore

// Presentation projections use the async database facade's reader snapshot, so
// related rows share one committed revision without UI-thread SQL or N awaits.
extension WorkspaceDatabase {
  public func openClawCronPresentation(limits: [String: Int]) async throws -> (
    jobs: [OpenClawCronJob], runs: [OpenClawCronRun], hasOlder: Set<String>, routes: [UUID: [String: String]]
  ) {
    try await read { connection in
      let jobs = try connection.openClawCronJobs()
      var runs: [OpenClawCronRun] = []
      var hasOlder: Set<String> = []
      var routes: [UUID: [String: String]] = [:]
      for job in jobs {
        let key = DashboardStore.openClawCronHistoryKey(agentID: job.agentID, jobID: job.id)
        let limit = max(1, min(limits[key] ?? 50, Int.max - 1))
        let page = try connection.openClawCronRuns(agentID: job.agentID, jobID: job.id, limit: limit + 1)
        runs.append(contentsOf: page.prefix(limit))
        if page.count > limit { hasOlder.insert(key) }
        if routes[job.agentID] == nil { routes[job.agentID] = try connection.openClawResultRoutes(agentID: job.agentID) }
      }
      return (jobs, runs, hasOlder, routes)
    }
  }

  public func sessionNativeWorkingDirectories(ids: [String]) async throws -> [String: String] {
    try await read { connection in
      var result: [String: String] = [:]
      for id in ids { result[id] = (try? connection.toolSessionCreationConfiguration(targetID: id))?.nativeWorkingDirectory }
      return result
    }
  }
}
