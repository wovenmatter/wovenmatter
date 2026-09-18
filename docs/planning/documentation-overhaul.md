# Documentation style and website plan

## Voice and priorities

The [README](../../README.md) sets the product story, feature order, and writing
style. Write for someone who knows AI agents and harnesses but may not be an
engineer. Explain what they can do in the app without making Git or terminal
workflows the starting point.

Lead with **The workspace for all of your harnesses.** Name all eight harnesses,
then explain the shared root within each workspace and the central work history.
Remote workspaces, panels, notes, and usage support that story. Keep the other
features concise and link to practical guides for detail.

Use direct sentences and familiar words. Prefer “work history,” “conversations,”
and “items created in WovenMatter” over internal storage terminology. Define
“runtime” when it appears in a guide because that is the label used in Settings.
Use short headings without periods. Describe features through their workflows;
avoid broad maturity labels and promotional claims that lack evidence.

## Keep claims consistent

- Each local or remote workspace has its own root shared by its agents.
- The local SQLite database saves conversations, notes, and other app items.
- Saving transcripts centrally does not copy every generated file or synchronize
  workspace folders.
- Agents can use shared workspace files and the note tools supplied for their
  conversation; do not equate that access with unrestricted access to all transcripts.
- Up to five panels can be visible while more sessions run in the background.
- Provider accounts, models, permissions, and background execution depend on the
  selected harness and service.
- The published app requires Apple silicon and macOS 26 or later. Tailscale
  discovery is optional; remote connections use the user's SSH configuration.

The code determines operational details; the README determines how we explain
them. Check both when changing a guide. Release notes carry version-specific
changes so the README does not become a second release history.

## Source map

The consistency review used main at `37f9734`. These are the main sources for
future documentation updates:

| Topic | Source |
| --- | --- |
| Harness catalog | [catalog.json](../../harnesses/catalog.json) |
| Settings and navigation | [SettingsView.swift](../../app/App/Views/SettingsView.swift) |
| Panels | [ChatPanelLayout.swift](../../app/Sources/WovenMatterCore/ChatPanelLayout.swift) |
| Workspace layout | [initialize-workspace.sh](../../harnesses/initialize-workspace.sh) and [LocalACPWorkspace.swift](../../app/Sources/WovenMatterClient/LocalACPWorkspace.swift) |
| Notes and agent access | [ApplicationModel.swift](../../app/App/ApplicationModel.swift) and [NoteEditingProtocol.swift](../../app/Sources/WovenMatterCore/NoteEditingProtocol.swift) |
| Saved conversations and imports | [WorkspaceDatabase.swift](../../app/Sources/WovenMatterDashboardStore/WorkspaceDatabase.swift) |
| Remote connection and lifecycle | [RemoteWorkspaceClient.swift](../../app/Sources/WovenMatterClient/RemoteWorkspaceClient.swift) and [remote-workspace.sh](../../scripts/remote-workspace.sh) |
| Remote data limits | [database-catalog.py](../../remote/src/database-catalog.py) |

User guides describe actions and outcomes. Technical references retain exact
contracts and limits. Historical audits retain their dates, revisions, and
validation evidence; they should not be read as current setup instructions.
Legal notices, security policies, and release instructions retain their own
requirements rather than borrowing the README's promotional language.

## Website structure

Reuse the guides as the source for a future `/docs` section:

- `/docs` — guide navigation.
- `/docs/getting-started` — download through first conversation.
- `/docs/agents` and `/docs/conversations` — setup and parallel work.
- `/docs/workspaces` and `/docs/remote-workspaces` — locations and persistence.
- `/docs/notes-and-data` and `/docs/schedules-and-usage` — supporting workflows.
- `/docs/troubleshooting` — recovery and support.

These are proposed routes, not deployed pages. Maintain one editable source per
guide, rewrite relative links for the site, and keep engineering references linked
to GitHub. Add release-matched screenshots and a short Codex example when preparing
the site. Verify a clean-install walkthrough before publication.

The [original interview](interview.md) records the starting questions. The
approved README and the guidance above supersede earlier editorial suggestions.
