# Documentation overhaul: first pass

## Editorial direction

Lead with the work a person can do, then show the shortest route to a first
conversation. Give local and remote agents clear places in the story. Treat
notes, databases, scheduling, and usage as supporting workflows, and keep
implementation and contribution details in references.

This is a proposed structure for review, not a finalized positioning statement.
The [interview](interview.md) is the next step before expanding the public copy.

## Source review

Drafted against main at `37f9734`; GitHub's latest published release was `v0.1.8`
on September 17, 2026. The README links to latest releases instead of maintaining
a second version number. The project file's default marketing version is not
the release history. Pending iPhone and workspace-history PRs are not described
as available features.

| Area | Implementation used for this draft |
| --- | --- |
| Navigation and chat organization | `DashboardSidebar.swift`, `WorkspaceView.swift`, `DashboardConversation.swift` |
| Setup and terminology | `SettingsView.swift`, `SettingsLocalWorkspaceView.swift`, `SettingsComponents.swift` |
| Folder layout and external links | `harnesses/initialize-workspace.sh`, `LocalACPWorkspace.swift` |
| App persistence | `ApplicationModel.swift`, `WorkspaceDatabase.swift`, `DashboardStore.swift` |
| Runtime catalog and maintenance | `harnesses/catalog.json`, `RuntimeMaintenance.swift`, `remote/src/runtime-maintenance.mjs` |
| Remote host and lifecycle | `SettingsRemoteWorkspacesView.swift`, `RemoteWorkspacesModel.swift`, `scripts/remote-workspace.sh`, `remote/compose.yaml` |
| Notes and data | `DashboardNotePane.swift`, `NoteDocument.swift`, `AgentDatabaseCatalog.swift`, `remote/src/database-catalog.py` |
| Scheduling and usage | `DashboardOpenClawCron.swift`, `DashboardHermesCron.swift`, `DashboardCalendarView.swift`, `SettingsUsageView.swift` |
| Service-specific behavior | OpenCode and Hermes integration references plus their client and coordinator implementations |

This was a source review, not a fresh installation walkthrough or provider-backed
acceptance test. Before publishing a website guide, verify its screenshots and
steps against the release being documented.

## Existing documentation

The README is now a user landing page. The guide directory provides short,
task-oriented pages. Detailed remote lifecycle and database contracts have moved
to reference pages so they remain available without dominating onboarding.
Contributor setup lives in CONTRIBUTING; the existing maintainer, security,
style, integration, and audit documents keep their specialist roles.

Corrected the stale Hermes ACP description and OpenCode remote-support exclusion.
The Hermes integration's old merge instructions are now marked as historical.
Keep audit dates and acceptance limits intact; rewriting prose must not turn
past fixture checks into claims of current live validation.

## Possible website structure

Reuse the Markdown guides as the source for a future `/docs` section:

- `/docs` — start here and guide navigation.
- `/docs/getting-started` — download through first conversation.
- `/docs/agents` and `/docs/conversations` — choose an agent and do work.
- `/docs/workspaces` and `/docs/remote-workspaces` — locations and persistence.
- `/docs/notes-and-data` and `/docs/schedules-and-usage` — supporting workflows.
- `/docs/troubleshooting` — recovery and support.

These are proposed routes, not deployed pages. Decide how the website consumes
these files before copying them; maintain one editable source per guide. Rewrite
relative links for the site and keep engineering references linked to GitHub.

## Next pass after the interview

Use the answers to settle audience, headline, feature order, and the first
walkthrough. Follow up on concrete examples and on promises about unattended work,
privacy, and costs. Then add a small set of release-matched screenshots and one
complete example, verify setup on a clean installation, and review the website
navigation and support wording before publication.
