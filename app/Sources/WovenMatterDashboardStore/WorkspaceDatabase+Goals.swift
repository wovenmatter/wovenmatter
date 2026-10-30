import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabaseConnection {
    func migrateGoals() throws {
        try transaction {
            try executeUnlocked("""
                CREATE TABLE IF NOT EXISTS workspace_session_goals(
                  session_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id) ON DELETE CASCADE, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS workspace_goal_runs(
                  goal_id TEXT NOT NULL, run_id TEXT NOT NULL, PRIMARY KEY(goal_id,run_id));
                CREATE TABLE IF NOT EXISTS workspace_goal_usage(
                  goal_id TEXT NOT NULL, run_id TEXT NOT NULL, tokens INTEGER NOT NULL,
                  PRIMARY KEY(goal_id,run_id));
                CREATE TRIGGER IF NOT EXISTS workspace_goal_cleanup BEFORE DELETE ON workspace_session_goals BEGIN
                  DELETE FROM workspace_goal_runs WHERE goal_id=json_extract(old.value,'$.id');
                  DELETE FROM workspace_goal_usage WHERE goal_id=json_extract(old.value,'$.id');
                END;
                """)
            if try historyRowsUnlocked("SELECT 1 FROM workspace_tool_schema WHERE version=2", values: []).isEmpty {
                // Add the goal tool to older stored selections once without
                // changing any previously selected optional tool groups.
                var settings = try toolSettingsUnlocked()
                settings.enabledByDefault.insert(.goals)
                try toolsExecuteUnlocked("UPDATE workspace_tool_settings SET value=? WHERE id=1", [try toolsJSON(settings)])
                for row in try historyRowsUnlocked("SELECT session_id,enabled_json FROM workspace_session_tools", values: []) {
                    guard let id = row.objectValue?["session_id"]?.stringValue,
                          let json = row.objectValue?["enabled_json"]?.stringValue else { continue }
                    var groups = try JSONDecoder().decode(Set<WorkspaceToolGroup>.self, from: Data(json.utf8))
                    groups.insert(.goals)
                    try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=? WHERE session_id=?", [try toolsJSON(groups), id])
                }
                try executeUnlocked("INSERT INTO workspace_tool_schema(version) VALUES(2)")
            }
        }
    }

    func goalUnlocked(_ sessionID: String) throws -> WorkspaceGoal? {
        guard let json = try historyRowsUnlocked("SELECT value FROM workspace_session_goals WHERE session_id=?", values: [sessionID])
            .first?.objectValue?["value"]?.stringValue else { return nil }
        var goal = try JSONDecoder().decode(WorkspaceGoal.self, from: Data(json.utf8))
        goal.completedTurns = try historyRowsUnlocked("SELECT count(*) AS count FROM workspace_goal_runs g JOIN dashboard_runs r ON r.id=g.run_id WHERE g.goal_id=? AND r.status='completed'", values: [goal.id]).first?.objectValue?["count"]?.intValue ?? goal.completedTurns
        return goal
    }

    func saveGoalUnlocked(_ goal: WorkspaceGoal) throws {
        try toolsExecuteUnlocked("INSERT INTO workspace_session_goals(session_id,value) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET value=excluded.value",
            [goal.sessionID, try toolsJSON(goal)])
    }

    func captureGoalRunsUnlocked(_ goal: inout WorkspaceGoal) throws {
        guard goal.status == .active else { return }
        try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_goal_runs(goal_id,run_id) SELECT ?,id FROM dashboard_runs WHERE conversation_id=? AND rowid>?", [goal.id, goal.sessionID, String(goal.enrolledRunSequence)])
        goal.enrolledRunSequence = try historyRowsUnlocked("SELECT coalesce(max(rowid),0) AS sequence FROM dashboard_runs WHERE conversation_id=?", values: [goal.sessionID]).first?.objectValue?["sequence"]?.goalInteger ?? goal.enrolledRunSequence
        // Newly enrolled runs may already be complete. Budget checks in this
        // transaction must include them before reserving another continuation.
        goal.completedTurns = try historyRowsUnlocked("SELECT count(*) AS count FROM workspace_goal_runs g JOIN dashboard_runs r ON r.id=g.run_id WHERE g.goal_id=? AND r.status='completed'", values: [goal.id]).first?.objectValue?["count"]?.intValue ?? goal.completedTurns
    }

    public func sessionGoals() throws -> [WorkspaceGoal] {
        try withLock {
            try historyRowsUnlocked("""
                SELECT g.value FROM workspace_session_goals g JOIN dashboard_conversations c ON c.id=g.session_id
                WHERE c.deleted_at IS NULL AND c.is_archived=0 ORDER BY g.session_id
                """, values: []).compactMap { row in
                    guard let json = row.objectValue?["value"]?.stringValue else { return nil }
                    var goal = try JSONDecoder().decode(WorkspaceGoal.self, from: Data(json.utf8))
                    goal.completedTurns = try historyRowsUnlocked("SELECT count(*) AS count FROM workspace_goal_runs g JOIN dashboard_runs r ON r.id=g.run_id WHERE g.goal_id=? AND r.status='completed'", values: [goal.id]).first?.objectValue?["count"]?.intValue ?? goal.completedTurns
                    return goal
                }
        }
    }

    func cancelQueuedGoalDeliveryUnlocked(_ goal: WorkspaceGoal) throws {
        guard let id = goal.pendingDeliveryID else { return }
        try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE id=? AND (status='queued' OR (status='sending' AND transport_started=0))", [id])
    }

    private func requireGoalExecutionSessionUnlocked(_ sessionID: String) throws {
        let row = try historyRowsUnlocked("""
            SELECT s.runtime_kind FROM desktop_local_acp_sessions s
            JOIN dashboard_conversations c ON c.id=s.conversation_id
            WHERE s.conversation_id=? AND c.desktop_owned=1 AND c.is_archived=0 AND c.deleted_at IS NULL
              AND \(PairedLibraryOwnership.localConversation("c.id"))
            """, values: [sessionID]).first
        guard let kind = row?.objectValue?["runtime_kind"]?.stringValue.flatMap(AgentRuntimeKind.init(rawValue:)) else {
            throw WorkspaceToolError.invalid("Goals require an active chat on its desktop execution owner.")
        }
        guard WorkspaceGoal.supports(kind) else {
            throw WorkspaceToolError.invalid("Goals require Pi Durable, Codex, Claude Code, Grok Build or OpenCode.")
        }
    }

    public func mutateGoal(sessionID: String, mutation: WorkspaceGoalMutation, callerID: String? = nil,
                           requestID: String? = nil, now: Date = Date()) throws -> WorkspaceGoal? {
        try transaction {
            try requireToolSessionUnlocked(sessionID)
            // Goal accounting uses the owner's local run sequence. A paired
            // observer cannot change it without the execution owner.
            guard try locallyOwnsConversationUnlocked(sessionID) else {
                throw WorkspaceToolError.invalid("Change this goal on the Mac that runs this chat.")
            }
            switch mutation {
            case .set, .resume: try requireGoalExecutionSessionUnlocked(sessionID)
            default: break
            }
            if let callerID {
                guard callerID == sessionID || callerID == WovenMCPCaller.outside else { throw WorkspaceToolError.invalid("An agent can only change its own goal.") }
                try requireToolUnlocked(.goals, sessionID: callerID)
            }
            return try performToolMutationUnlocked(callerID: callerID, requestID: requestID, operation: callerID == WovenMCPCaller.outside ? "goals.mutate:" + sessionID : "goals.mutate", input: mutation) {
                var goal = try goalUnlocked(sessionID)
                if case let .set(objective, tokens, turns) = mutation {
                    try requireToolUnlocked(.goals, sessionID: sessionID)
                    guard goal == nil || goal?.status == .complete else { throw WorkspaceToolError.invalid("A goal already exists. Edit or clear it before setting another.") }
                    try WorkspaceGoal.validate(objective: objective, tokenBudget: tokens, turnBudget: turns)
                    if goal != nil {
                        // Replacing an achieved goal starts fresh accounting. Deleting
                        // its row also removes the previous run and usage membership.
                        try toolsExecuteUnlocked("DELETE FROM workspace_session_goals WHERE session_id=?", [sessionID])
                    }
                    // Include an in-flight turn which explicitly created the goal.
                    let rows = try historyRowsUnlocked("SELECT rowid AS sequence,status FROM dashboard_runs WHERE conversation_id=? ORDER BY rowid DESC LIMIT 1", values: [sessionID])
                    let sequence = rows.first?.objectValue?["sequence"]?.goalInteger ?? 0
                    let running = ["queued", "accepted", "running"].contains(rows.first?.objectValue?["status"]?.stringValue ?? "")
                    goal = WorkspaceGoal(sessionID: sessionID, objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
                        tokenBudget: tokens, turnBudget: turns, baselineRunSequence: running ? max(0, sequence - 1) : sequence, now: now)
                } else {
                    guard var current = goal else { throw WorkspaceToolError.notFound("No goal is set.") }
                    try captureGoalRunsUnlocked(&current)
                    let id: String
                    switch mutation {
                    case .set: preconditionFailure()
                    case .edit(let value, _, _, _), .pause(let value), .resume(let value), .clear(let value),
                         .complete(let value, _), .block(let value, _), .checkpoint(let value, _): id = value
                    }
                    guard id == current.id else { throw WorkspaceToolError.invalid("The goal changed. Read the current goal before retrying.") }
                    switch mutation {
                    case .set: break
                    case let .edit(_, objective, tokens, turns):
                        try WorkspaceGoal.validate(objective: objective, tokenBudget: tokens, turnBudget: turns)
                        try cancelQueuedGoalDeliveryUnlocked(current)
                        current.pendingDeliveryID = nil
                        let oldID = current.id
                        current.id = UUID().uuidString.lowercased()
                        try toolsExecuteUnlocked("UPDATE workspace_goal_runs SET goal_id=? WHERE goal_id=?", [current.id, oldID])
                        try toolsExecuteUnlocked("UPDATE workspace_goal_usage SET goal_id=? WHERE goal_id=?", [current.id, oldID])
                        current.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                        current.tokenBudget = tokens; current.turnBudget = turns
                        current.status = .paused; current.evidence = "Goal edited. Resume to continue."
                    case .pause:
                        guard current.status != .complete else { throw WorkspaceToolError.invalid("This goal is complete. Set a new goal.") }
                        try cancelQueuedGoalDeliveryUnlocked(current)
                        current.status = .paused
                    case .resume:
                        try requireToolUnlocked(.goals, sessionID: sessionID)
                        // An already active goal keeps its pending delivery and
                        // progress fences; Resume must not create a second turn.
                        if current.status == .active { break }
                        guard current.status != .complete else { throw WorkspaceToolError.invalid("This goal is complete. Set a new goal.") }
                        guard current.tokenBudget.map({ (current.tokensUsed ?? 0) < $0 }) ?? true,
                              current.turnBudget.map({ current.completedTurns < $0 }) ?? true else {
                            throw WorkspaceToolError.invalid("Increase or remove the goal budget before resuming.")
                        }
                        let latest = try historyRowsUnlocked("SELECT rowid AS sequence,status FROM dashboard_runs WHERE conversation_id=? ORDER BY rowid DESC LIMIT 1", values: [sessionID]).first?.objectValue
                        let sequence = latest?["sequence"]?.goalInteger ?? current.enrolledRunSequence
                        let running = ["queued", "accepted", "running"].contains(latest?["status"]?.stringValue ?? "")
                        // A conversational Resume enrolls its current turn, while
                        // ordinary work completed during the pause stays excluded.
                        let resumingTurn = running && sequence > current.enrolledRunSequence
                        current.enrolledRunSequence = resumingTurn ? max(0, sequence - 1) : sequence
                        current.observedRunSequence = current.enrolledRunSequence
                        current.status = .active; current.evidence = nil
                        if let pending = current.pendingDeliveryID,
                           try historyRowsUnlocked("SELECT status FROM workspace_session_deliveries WHERE id=?", values: [pending]).first?.objectValue?["status"]?.stringValue != "uncertain" {
                            current.pendingDeliveryID = nil
                        }
                    case .clear:
                        try cancelQueuedGoalDeliveryUnlocked(current)
                        try toolsExecuteUnlocked("DELETE FROM workspace_session_goals WHERE session_id=?", [sessionID])
                        return Optional<WorkspaceGoal>.none
                    case .complete(_, let evidence), .block(_, let evidence), .checkpoint(_, let evidence):
                        let clean = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty, clean.utf8.count <= 4_096 else { throw WorkspaceToolError.invalid("Supply concrete evidence of at most 4 KiB.") }
                        guard current.status == .active else { throw WorkspaceToolError.invalid("Only an active goal can report progress or completion.") }
                        if clean != current.evidence { current.progressRevision += 1 }
                        current.evidence = clean
                        if case .complete = mutation { current.status = .complete }
                        if case .block = mutation { current.status = .blocked }
                        if current.status != .active { try cancelQueuedGoalDeliveryUnlocked(current) }
                    }
                    current.updatedAt = now; goal = current
                }
                if var current = goal { try captureGoalRunsUnlocked(&current); try saveGoalUnlocked(current); goal = current }
                return goal
            }.result
        }
    }

    /// Usage reports are cumulative per run. Retries and repeated native reports
    /// must not double-count, including a final report after completion or Stop.
    public func recordGoalUsage(runID: String, tokens: Int64) throws {
        try transaction { try recordGoalUsageUnlocked(runID: runID, tokens: tokens) }
    }

    func recordGoalUsageUnlocked(runID: String, tokens: Int64) throws {
        guard tokens >= 0, let run = try historyRowsUnlocked("SELECT conversation_id,rowid AS sequence FROM dashboard_runs WHERE id=?", values: [runID]).first?.objectValue,
              let sessionID = run["conversation_id"]?.stringValue, try locallyOwnsConversationUnlocked(sessionID), var goal = try goalUnlocked(sessionID) else { return }
        // Enrollment is by stable run ID: an enrolled run's late usage counts
        // whatever its row sequence; otherwise only runs after the baseline do.
        let enrolled = try historyRowsUnlocked("SELECT 1 AS enrolled FROM workspace_goal_runs WHERE goal_id=? AND run_id=?", values: [goal.id, runID]).isEmpty == false
        guard enrolled || (run["sequence"]?.goalInteger ?? 0) > goal.baselineRunSequence else { return }
        try captureGoalRunsUnlocked(&goal)
        guard try historyRowsUnlocked("SELECT 1 FROM workspace_goal_runs WHERE goal_id=? AND run_id=?", values: [goal.id, runID]).isEmpty == false else { return }
        let previous = try historyRowsUnlocked("SELECT tokens FROM workspace_goal_usage WHERE goal_id=? AND run_id=?", values: [goal.id, runID]).first?.objectValue?["tokens"]?.goalInteger ?? 0
        let next = max(previous, tokens)
        try toolsExecuteUnlocked("INSERT INTO workspace_goal_usage(goal_id,run_id,tokens) VALUES(?,?,?) ON CONFLICT(goal_id,run_id) DO UPDATE SET tokens=excluded.tokens", [goal.id, runID, String(next)])
        let total = (goal.tokensUsed ?? 0).addingReportingOverflow(next - previous)
        goal.tokensUsed = total.overflow ? Int64.max : total.partialValue
        try saveGoalUnlocked(goal)
    }

    public func pauseActiveGoals(sessionID: String? = nil, reason: String? = nil) throws {
        try transaction {
            // A synchronized goal belongs to its execution owner. Observers
            // read it but never pause, capture or account for it.
            for var goal in try sessionGoals() where goal.status == .active && (sessionID == nil || goal.sessionID == sessionID) {
                guard try locallyOwnsConversationUnlocked(goal.sessionID) else { continue }
                try captureGoalRunsUnlocked(&goal)
                try cancelQueuedGoalDeliveryUnlocked(goal)
                goal.status = .paused; goal.evidence = reason ?? goal.evidence; goal.updatedAt = Date()
                try saveGoalUnlocked(goal)
            }
        }
    }

    /// Reservations and terminal accounting commit atomically. Native acceptance
    /// uses the existing outbox and dispatch fences; uncertain work never replays.
    public func dueGoalDeliveries(running: Set<String>, now: Date = Date()) throws -> [WorkspaceSessionDelivery] {
        try transaction {
            var deliveries: [WorkspaceSessionDelivery] = []
            for var goal in try sessionGoals() where goal.status == .active {
                // Unknown or foreign ownership is read-only: no pause, capture,
                // reservation or delivery is written for another Mac's goal.
                guard try locallyOwnsConversationUnlocked(goal.sessionID) else { continue }
                do { try requireGoalExecutionSessionUnlocked(goal.sessionID) } catch {
                    goal.status = .paused; goal.evidence = "Execution ownership changed or this chat is archived."
                    try cancelQueuedGoalDeliveryUnlocked(goal); try saveGoalUnlocked(goal); continue
                }
                let original = goal
                try captureGoalRunsUnlocked(&goal)
                if goal != original { try saveGoalUnlocked(goal) }
                if try historyRowsUnlocked("SELECT 1 FROM dashboard_runs WHERE conversation_id=? AND status='uncertain' UNION ALL SELECT 1 FROM desktop_opencode_submissions WHERE conversation_id=? AND status='uncertain' LIMIT 1", values: [goal.sessionID, goal.sessionID]).isEmpty == false {
                    goal.status = .blocked; goal.evidence = "A native input has uncertain acceptance. Reconcile it before resuming the goal."
                    try cancelQueuedGoalDeliveryUnlocked(goal); try saveGoalUnlocked(goal)
                    continue
                }
                guard !running.contains(goal.sessionID) else { continue }
                if !((try? sessionToolsUnlocked(goal.sessionID).enabled.contains(.goals)) ?? false) {
                    goal.status = .paused; goal.evidence = "Goal tools are disabled."
                }
                let nativeBusy = try historyRowsUnlocked("""
                    SELECT 1 FROM desktop_opencode_sessions WHERE conversation_id=? AND
                      (json_extract(snapshot_json,'$.active')=1 OR json_array_length(snapshot_json,'$.permissions')>0 OR json_array_length(snapshot_json,'$.forms')>0)
                    UNION ALL SELECT 1 FROM desktop_opencode_submissions WHERE conversation_id=? AND status IN ('sending','uncertain') LIMIT 1
                    """, values: [goal.sessionID, goal.sessionID])
                guard nativeBusy.isEmpty else { continue }
                if try historyRowsUnlocked("SELECT 1 FROM desktop_local_acp_sessions WHERE conversation_id=? AND permission='plan'", values: [goal.sessionID]).isEmpty == false {
                    goal.status = .paused; goal.evidence = "Goal continuation is paused in Plan mode. Change permissions and resume to continue."
                }
                let active = try historyRowsUnlocked("SELECT 1 FROM dashboard_runs WHERE conversation_id=? AND status IN ('queued','accepted','running','uncertain') LIMIT 1", values: [goal.sessionID])
                guard active.isEmpty else { continue }
                if goal.tokenBudget.map({ (goal.tokensUsed ?? 0) >= $0 }) ?? false || goal.turnBudget.map({ goal.completedTurns >= $0 }) ?? false {
                    goal.status = .budgetLimited; goal.evidence = "The goal budget was reached. Increase or remove it to resume."
                }
                if goal.status != .active {
                    try cancelQueuedGoalDeliveryUnlocked(goal)
                    try saveGoalUnlocked(goal)
                    continue
                }
                // A previously reserved continuation must yield to newly queued inputs too.
                let unresolved = try historyRowsUnlocked("SELECT status FROM workspace_session_deliveries WHERE target_id=? AND ((status='uncertain' AND id!=?) OR (status IN ('queued','sending') AND kind!='goal')) ORDER BY CASE WHEN status='uncertain' THEN 0 ELSE 1 END LIMIT 1", values: [goal.sessionID, goal.pendingDeliveryID ?? ""])
                if let status = unresolved.first?.objectValue?["status"]?.stringValue {
                    if status == "uncertain" {
                        goal.status = .blocked; goal.evidence = "A previous input has uncertain delivery. Reconcile it before resuming the goal."
                        try cancelQueuedGoalDeliveryUnlocked(goal); try saveGoalUnlocked(goal)
                    }
                    continue
                }
                if let pending = goal.pendingDeliveryID {
                    let receipt = try historyRowsUnlocked("SELECT status FROM workspace_session_deliveries WHERE id=?", values: [pending]).first?.objectValue?["status"]?.stringValue
                    if receipt == "queued" {
                        if goal.status == .active, let delivery = try toolDelivery(id: pending) { deliveries.append(delivery) }
                        continue
                    }
                    if receipt == "sending" { continue }
                    if receipt != "accepted" {
                        goal.status = receipt == "cancelled" ? .paused : .blocked
                        goal.evidence = "Goal delivery is \(receipt ?? "unavailable"). Inspect it before resuming."
                    } else if goal.progressRevision == goal.pendingProgressRevision {
                        // Merely reading goal status uses a tool too. Require a
                        // new checkpoint so status-only turns cannot loop forever.
                        goal.status = .blocked
                        goal.evidence = "The agent ended a goal turn without reporting new progress or completion. Resume after checking its response."
                    }
                    goal.pendingDeliveryID = nil
                }
                let completed = try historyRowsUnlocked("SELECT rowid AS sequence,status FROM dashboard_runs WHERE conversation_id=? AND rowid>? ORDER BY rowid", values: [goal.sessionID, String(goal.observedRunSequence)])
                for run in completed {
                    guard let value = run.objectValue else { continue }
                    goal.observedRunSequence = max(goal.observedRunSequence, value["sequence"]?.goalInteger ?? 0)
                    if value["status"]?.stringValue != "completed" {
                        goal.status = .blocked; goal.evidence = "The latest goal run did not complete successfully. Inspect it before resuming."
                    }
                }
                if goal.tokenBudget.map({ (goal.tokensUsed ?? 0) >= $0 }) ?? false || goal.turnBudget.map({ goal.completedTurns >= $0 }) ?? false {
                    goal.status = .budgetLimited; goal.evidence = "The goal budget was reached. Increase or remove it to resume."
                } else if goal.tokenBudget != nil, try historyRowsUnlocked("""
                    SELECT 1 FROM workspace_goal_runs g JOIN dashboard_runs r ON r.id=g.run_id
                    LEFT JOIN workspace_goal_usage u ON u.goal_id=g.goal_id AND u.run_id=g.run_id
                    WHERE g.goal_id=? AND r.status NOT IN ('queued','accepted','running') AND u.run_id IS NULL LIMIT 1
                    """, values: [goal.id]).isEmpty == false {
                    goal.status = .blocked; goal.evidence = "This runtime did not report token usage for a settled goal turn. Remove the token budget or resolve usage reporting before resuming."
                }
                if goal != original { goal.updatedAt = now; try saveGoalUnlocked(goal) }
                guard goal.status == .active else { continue }
                // Pending user/tool inputs take precedence over automatic work.
                guard try historyRowsUnlocked("SELECT 1 FROM workspace_session_deliveries WHERE target_id=? AND (status='uncertain' OR (status IN ('queued','sending') AND kind!='goal')) LIMIT 1", values: [goal.sessionID]).isEmpty else { continue }
                let id = UUID().uuidString.lowercased()
                let delivery = try reserveToolDeliveryUnlocked(sourceID: goal.sessionID, targetID: goal.sessionID,
                    text: goal.continuationPrompt, requestID: id, kind: .goal)
                goal.pendingDeliveryID = delivery.id; goal.pendingProgressRevision = goal.progressRevision; goal.updatedAt = now
                try saveGoalUnlocked(goal)
                deliveries.append(delivery)
            }
            return deliveries
        }
    }

    func goalDeliveryAuthorizedUnlocked(sessionID: String, deliveryID: String) throws -> Bool {
        do { try requireGoalExecutionSessionUnlocked(sessionID) } catch { return false }
        guard let goal = try goalUnlocked(sessionID) else { return false }
        guard goal.status == .active, goal.pendingDeliveryID == deliveryID else { return false }
        return try sessionToolsUnlocked(sessionID).enabled.contains(.goals)
    }
}

extension WorkspaceDatabase {
    public func sessionGoals() async throws -> [WorkspaceGoal] { try await read { try $0.sessionGoals() } }
    public func mutateGoal(sessionID: String, mutation: WorkspaceGoalMutation, callerID: String? = nil,
                           requestID: String? = nil, dispatchFence: AgentDispatchFence? = nil) async throws -> WorkspaceGoal? {
        try await write { connection in
            // Stop may arrive while this job waits for the writer. Once this
            // synchronous job starts, a later Stop's pause is ordered after it.
            try dispatchFence?.check()
            return try connection.mutateGoal(sessionID: sessionID, mutation: mutation, callerID: callerID, requestID: requestID)
        }
    }
    public func pauseActiveGoals(sessionID: String? = nil, reason: String? = nil) async throws {
        try await finishWrite { try $0.pauseActiveGoals(sessionID: sessionID, reason: reason) }
    }
    public func recordGoalUsage(runID: String, tokens: Int64) async throws {
        try await finishWrite { try $0.recordGoalUsage(runID: runID, tokens: tokens) }
    }
    public func dueGoalDeliveries(running: Set<String>) async throws -> [WorkspaceSessionDelivery] {
        try await write { try $0.dueGoalDeliveries(running: running) }
    }
}

private extension GatewayJSONValue {
    var goalInteger: Int64? { intValue.map(Int64.init) }
}
