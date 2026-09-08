# OpenCode v2 test handoff

## Open the feature build

The feature worktree is `/private/tmp/wovenmatter-opencode-v2-integration`, branch `codex/opencode-v2-integration`. Build and launch from that worktree:

```sh
WOVENMATTER_DEV_VARIANT=OpenCode \
WOVENMATTER_DEV_CACHE_DIR=/private/tmp/wovenmatter-opencode-dev \
  scripts/build_and_run.sh
```

The running app is `/private/tmp/wovenmatter-opencode-dev/DerivedData/Build/Products/Debug/Woven Matter OpenCode Dev.app`. Its bundle ID is `wovenmatter.desktop.dev.opencode`; its database is `~/Library/Application Support/Woven Matter Dev/opencode/workspace.sqlite`. It can coexist with another Dev build. The standard build command still uses the regular Woven Matter workspace and preserves its existing transcripts.

The test variant currently connects to an isolated local beta service. Its connection is saved under Settings → Local Agent Workspace → OpenCode v2. It has no configured model-provider account. The `OpenCode v2 rendering fixture` transcript is explicitly imported test data, not a provider execution result. The terminal test ran only a `printf` command and verified disconnect/reconnect recovery.

## Installation and service selection

Installed for this test: `/private/tmp/wovenmatter-opencode-v2-runtime/node_modules/.bin/opencode2`, version `0.0.0-beta-19278`. The isolated service registration is `/private/tmp/wovenmatter-opencode-live/state/opencode/service.json`; the workspace is `/private/tmp/wovenmatter-opencode-live/project`. These temporary paths may disappear after system cleanup. The existing v1 executable was not overwritten.

For a regular installation, the pinned official package command is:

```sh
npm install -g @opencode/cli@0.0.0-beta-19278
```

Choose `opencode2` in the OpenCode settings card. To connect to a regular existing service, set the registration field to `~/.local/state/opencode/service.json` (enter its expanded absolute path), then choose Connect on This Mac. A configured `XDG_STATE_HOME` changes that path. Start Shared Service is explicit and only starts when no registration exists; Woven Matter never replaces or restarts an existing service automatically.

For a remote service, enter its explicit HTTP(S) origin and Basic credentials. The workspace field is an absolute directory on that host. Use an already available Tailnet address or user-managed SSH forwarding address. Woven Matter does not deploy the remote service or alter its authentication.

## Test the feature

1. OpenCode settings → Sessions opens existing sessions or creates a new one. New Chat → OpenCode creates a v2 session. Old v1 transcripts in the regular Woven Matter database remain readable and cannot send new input.
2. Use the per-session model/variant and agent menus. Configure provider credentials through Session → Integrations using the provider's actual method. Other sections expose files/diffs/worktrees, terminals, commands/skills/shell jobs, MCP, plugins, configuration, instructions/environment, and saved permissions.
3. Open the same session in OpenCode's own interface. Send from both interfaces; check history, tool activity, permission decisions, questions, and attachments.
4. Send follow-up input with Queue and Steer. Check the inbox in Session. Interrupt and Background Tools are explicit actions, independent from disconnecting.
5. Disconnect Woven Matter during a run, then reconnect. Confirm the transcript and pending interactions recover and input is not duplicated. An uncertain send stays unresolved until the backend confirms its identity or you explicitly acknowledge it; it is never silently retried.
6. For a persistent terminal, create/open a Session terminal, run a harmless command, disconnect its display and reopen the same terminal. The process and screen survive display disconnection.
7. Test compaction, fork/fork-before, export/import and staged revert on a disposable session/worktree. Revert commit, deletion, worktree removal and terminal termination are separate explicit actions.

Provider-backed execution, image round trips, live server restart during a run, remote hosts, OAuth and third-party MCP integrations still need human acceptance. See [PARITY.md](PARITY.md) for the capability-by-capability evidence and upstream limitations. Automated tests do not consume provider services.
