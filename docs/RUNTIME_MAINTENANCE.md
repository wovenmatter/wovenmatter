# Runtime installation and updates

Technical reference. For everyday setup, start with [Agent setup](guide/agents.md).

## Runtime controls

**Settings → Local agent workspace** shows the executable and components used
by each harness. Missing components show **Install**; verified installations
can be enabled. Opening settings refreshes the inventory. Enabled runtimes also
check versions at startup or reopen, without a repeating timer.

**Check for updates** reports available versions. **Update** installs an observed
update. Network failures leave the latest version unknown. Both actions remain
available for retry after a failure. After two failures in an app session,
**Copy diagnostic** offers component versions and an error category without raw
command output, account data, paths, or credentials.

## Components and updates

| Runtime | Actual local architecture | Release source and action |
| --- | --- | --- |
| Codex | `codex-acp`, bundled `@openai/codex`, standalone `codex` for sign-in; inherited `CODEX_PATH` overrides are reported | Official npm registry, exact adapter version; official Codex installer for outdated sign-in CLI. Adapter minimum is 1.11.0. No `CODEX_PATH` is set. |
| Claude Code | `claude-agent-acp`, bundled `@anthropic-ai/claude-agent-sdk` and its platform-native Claude engine (legacy `cli.js` also supported), standalone `claude` sign-in CLI; inherited executable override is reported | Official npm adapter release; `claude update` for an outdated standalone CLI. |
| Pi | `pi --mode rpc`, not ACP | Official `@earendil-works/pi-coding-agent` npm releases; exact managed package install. |
| OpenCode | `opencode2` and separately running standard v2 service | Exact supported `@opencode/cli` prerelease; never use the reserved `latest` tag. Install/repair verifies the supported version. Arbitrary newer v2 releases require app compatibility work. Registered service version is shown separately and is not a live-health assertion. Existing service is not restarted. |
| OpenClaw | Local `openclaw` CLI and separately linked gateways | Official npm `openclaw` release, managed CLI update. Does not update/restart gateways or install their provider runtimes. |
| Cursor | Native `cursor-agent acp` | Version embedded in official Cursor installer; `cursor-agent update`. Same-date release hashes cannot be ordered and are not asserted to be newer. |
| Grok Build | `grok … agent stdio` | Official stable release endpoint used by installer; `grok update`. |
| Hermes | `hermes serve --isolated`, native server version, and verified `serve --help` support | Official installer for missing CLI. `hermes update --check` reports current/available/unknown. Update verifies a clean source checkout, requires an idle plan and no active Hermes processes, then runs `hermes update --yes` with a 600-second limit. Completion requires a current update check and successful native Gateway validation. |

## Local installation

Managed npm installs are staged in `Node Tools/Installations/<UUID>` and verified
before an atomic launcher symlink replacement in `Node Tools/bin`. Old generations
are retained so running adapters retain their dependency trees; automatic garbage
collection is deliberately absent. Existing flat managed installs remain readable.
Subprocesses have a bounded duration and their own process group, so a timed-out
shell's children cannot continue an installation after retry becomes available.
New local message sends and maintenance actions are mutually gated during a local
runtime operation. No operation cancels an active turn.

## Remote installation

Each remote agent workspace has its own inventory, preferences, latest checks and
verified maintenance actions, served by that workspace's authenticated service
through its SSH tunnel. Installers execute on the selected host. Remote services
must include these endpoints before the controls are available. Buzz remains
outside this management surface. Local package presence never verifies a remote
installation or a linked gateway's runtime.

On first inventory, runtimes without saved preferences retain their previous
availability only after all required components verify. Missing runtimes become
disabled and remain so after later installation until explicitly enabled. Saved
Disable/Hide choices survive service restarts; unreadable preferences fail closed.

Remote adapter inventories show upstream bundled-package versions separately
from the compatible update target resolved using the adapter's dependency range.
Updates refresh that dependency within the declared range and verify the result;
unknown compatibility does not produce an update claim. Hermes uses the same
bounded direct updater and verification on the selected host. It preserves
modified source checkouts by refusing to update until those changes are saved.

Remote maintenance takes an exclusive lock in the workspace container. Remote conversation processes
and managed OpenCode/OpenClaw servers hold shared locks for their lifetime, so an
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

OpenClaw settings open workspace-specific gateway controls and the actual agent
name/gateway settings. The remote service proxies only a gateway process it owns,
and rejects an unrelated listener on the configured port. Starting, stopping and
configuration belong to the selected workspace; local controls do not operate on
remote or Buzz gateways. Installing a CLI does not install provider runtimes or
upgrade independently linked gateways.

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
- [Pi package](https://registry.npmjs.org/@earendil-works%2fpi-coding-agent/latest).
- [OpenCode package](https://registry.npmjs.org/@opencode%2fcli/latest): reserved
  placeholder; app's supported prerelease remains the compatibility authority.
- [Cursor installation/update](https://docs.cursor.com/en/cli/installation) and
  [official installer](https://cursor.com/install).
- [Grok CLI reference](https://docs.x.ai/build/cli/reference) and
  [official installer](https://x.ai/cli/install.sh).
- [OpenClaw updates](https://docs.openclaw.ai/install/updating).
- [Hermes updates](https://nousresearch.github.io/hermes-agent/docs/getting-started/updating/).
  Direct update behavior follows its [updater implementation](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/subcommands/update.py)
  and [service inventory](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/update_inventory.py).
