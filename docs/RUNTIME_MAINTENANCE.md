# Runtime installation and updates

Technical reference. For everyday setup, start with [Agent setup](guide/agents.md).

## Runtime controls

**Settings → Local Agent Workspace** shows the executable and components used
by each harness. Missing components show **Install**; verified installations
appear in the sidebar automatically. **Sign in…** opens the native harness's
account flow in Terminal, and returning to Woven Matter refreshes its status.
Opening settings refreshes the inventory and available versions, without a
repeating timer. **Settings → General → Set up harnesses** reopens the first-launch
guide, including optional Pi Durable provider and Exa setup. The provider page
contains only OpenAI, Anthropic, Grok, OpenRouter, and OpenCode; the web-search
page contains the Exa key form. These focused pages are also available from
**Settings → Pi Durable**.

**Check for updates** reports available versions. **Update** installs an observed
update. Network failures leave the latest version unknown. Both actions remain
available for retry after a failure. After two failures in an app session,
**Copy diagnostic** offers component versions and an error category without raw
command output, account data, paths, or credentials.

## Components and updates

| Runtime | Actual local architecture | Release source and action |
| --- | --- | --- |
| Codex | `codex-acp`, bundled `@openai/codex`, standalone `codex` for sign-in; inherited `CODEX_PATH` overrides are reported | Newest official npm adapter release; official Codex installer for outdated sign-in CLI. Adapter minimum is 1.13.1; it is a compatibility floor, never an installation fallback. No `CODEX_PATH` is set. |
| Claude Code | `claude-agent-acp`, bundled `@anthropic-ai/claude-agent-sdk` and its platform-native Claude engine (legacy `cli.js` also supported), standalone `claude` sign-in CLI; inherited executable override is reported | Official npm adapter release; `claude update` for an outdated standalone CLI. |
| OpenCode | `opencode` (with `opencode2` fallback) and separately running standard v2 service | Newest stable `@opencode/cli` 2.x release; each install/update resolves a fresh compatible release even if upstream `latest` advances to a new major. Minor and patch updates are independently supported. Registered service version is shown separately and is not a live-health assertion. Existing service is not restarted. |
| Grok Build | `grok … agent stdio` | Official stable release endpoint used by installer; `grok update`. |

## Local installation

Managed npm installs are staged in `Node Tools/Installations/<UUID>` and verified
before an atomic launcher symlink replacement in `Node Tools/bin`. Old generations
are retained so running adapters retain their dependency trees; automatic garbage
collection is deliberately absent. Existing flat managed installs remain readable.
Subprocesses have a bounded duration and their own process group, so a timed-out
shell's children cannot continue an installation after retry becomes available.
Different local harnesses can update concurrently. Each harness keeps its own
progress, failure, and installation lock; duplicate operations on the same
harness are rejected. Shared Node bootstrap is coalesced, while npm packages use
separate staging directories and atomic launcher promotion. New local message
sends and maintenance actions are mutually gated during a local runtime
operation. No operation cancels an active turn.

## Remote installation

Each remote agent workspace has its own inventory, preferences, latest checks and
verified maintenance actions, served by that workspace's authenticated service
through its SSH tunnel. Installers execute on the selected host. Remote services
must include these endpoints before the controls are available.
Local package presence never verifies a remote
installation or a linked gateway's runtime.

On first inventory, runtimes without saved preferences retain their previous
availability only after all required components verify. Missing runtimes become
disabled and remain so after later installation until explicitly enabled. Saved
Disable/Hide choices survive service restarts; unreadable preferences fail closed.

Remote adapter inventories show upstream bundled-package versions separately
from the compatible update target resolved using the adapter's dependency range.
Updates refresh that dependency within the declared range and verify the result;
unknown compatibility does not produce an update claim.

Remote maintenance takes an exclusive lock in the workspace container. Remote conversation processes
and managed OpenCode servers hold shared locks for their lifetime, so an
update cannot replace their runtime while they are using it. A busy workspace requires
the user to finish conversations or stop its server before retrying maintenance.
Installer timeouts terminate the process group before permitting another attempt.

## Service controls

OpenCode settings open the selected workspace's server and model settings. Each
remote workspace owns a distinct v2 service state directory and conversation
association; the app routes requests and event streams to its authenticated
workspace proxy. The service's Basic credential stays on the remote host. The
native client uses the workspace bearer credential over a loopback SSH tunnel;
no public OpenCode listener or remote browser credential URL is created. Local
OpenCode retains its existing registered service and explicit lifecycle controls.

## Upstream reference snapshot — September 11, 2026

The versions below record the earlier source review. For the app's declared
packages and checks, use [the harness catalog](../harnesses/catalog.json),
[local maintenance](../app/Sources/WovenMatterClient/RuntimeMaintenance.swift),
and [remote maintenance](../remote/src/runtime-maintenance.mjs).

- [Codex adapter](https://github.com/agentclientprotocol/codex-acp) and
  [npm metadata](https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest):
  1.11.0 declares `@openai/codex ^0.153.4`.
- [Claude adapter](https://github.com/agentclientprotocol/claude-agent-acp) and
  [npm metadata](https://registry.npmjs.org/@agentclientprotocol%2fclaude-agent-acp/latest):
  0.76.0 declares SDK 0.3.257.
- [OpenCode package](https://registry.npmjs.org/@opencode%2fcli/latest): the current
  stable v2 release; each install/update resolves this tag afresh.
- [Grok CLI reference](https://docs.x.ai/build/cli/reference) and
  [official installer](https://x.ai/cli/install.sh).
