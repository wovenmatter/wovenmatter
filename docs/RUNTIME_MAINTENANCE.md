# Runtime installation and updates

Local Workspace runtime rows inventory the selected executable and required
components. Install replaces Enable until those requirements are verified. Enabled
runtimes fetch release information once at startup/reopen; opening settings also
refreshes inventory. There is no repeating version timer and checking never
installs anything. Network failures leave latest versions unknown. An Update
button appears only for an observed newer version. Failed operations remain
retryable; after two failures in this app session the row offers a copyable,
allowlisted diagnostic with component versions and an error category. Raw command
output, account data, paths and credentials are not copied.

| Runtime | Actual local architecture | Release source and action |
| --- | --- | --- |
| Codex | `codex-acp`, bundled `@openai/codex`, standalone `codex` for sign-in; inherited `CODEX_PATH` overrides are reported | Official npm registry, exact adapter version; official Codex installer for outdated sign-in CLI. Adapter minimum is 1.11.0. No `CODEX_PATH` is set. |
| Claude Code | `claude-agent-acp`, bundled `@anthropic-ai/claude-agent-sdk` and its platform-native Claude engine (legacy `cli.js` also supported), standalone `claude` sign-in CLI; inherited executable override is reported | Official npm adapter release; `claude update` for an outdated standalone CLI. |
| Pi | `pi --mode rpc`, not ACP | Official `@earendil-works/pi-coding-agent` npm releases; exact managed package install. |
| OpenCode | `opencode2` and separately running standard v2 service | Exact supported `@opencode/cli` prerelease; never use the reserved `latest` tag. Install/repair verifies the supported version. Arbitrary newer v2 releases require app compatibility work. Registered service version is shown separately and is not a live-health assertion. Existing service is not restarted. |
| OpenClaw | Local `openclaw` CLI and separately linked gateways | Official npm `openclaw` release, managed CLI update. Does not update/restart gateways or install their provider runtimes. |
| Cursor | Native `cursor-agent acp` | Version embedded in official Cursor installer; `cursor-agent update`. Same-date release hashes cannot be ordered and are not asserted to be newer. |
| Grok Build | `grok … agent stdio` | Official stable release endpoint used by installer; `grok update`. |
| Hermes | `hermes acp`, existing Python environment/profile | Official installer for missing CLI. `hermes update --check` reports current/available/unknown without installing. Exact latest version remains unavailable because upstream tracks git main. Available updates link to the official guide: use `hermes update --plan` and then deliberate Terminal maintenance, since updates may restart all profiles/services. No automatic Hermes update is offered. |

Managed npm installs are staged in `Node Tools/Installations/<UUID>` and verified
before an atomic launcher symlink replacement in `Node Tools/bin`. Old generations
are retained so running adapters retain their dependency trees; automatic garbage
collection is deliberately absent. Existing flat managed installs remain readable.
Subprocesses have a bounded duration and their own process group, so a timed-out
shell's children cannot continue an installation after retry becomes available.
New local message sends and maintenance actions are mutually gated during a local
runtime operation. No operation cancels an active turn.

OpenCode's running service may continue using its previous executable after an
installation. Its existing More controls retain deliberate server lifecycle
control. Gateway rows and Buzz/Remote Workspace sections refer to different hosts
and ownership boundaries: local package presence cannot verify or upgrade their
servers, container images, gateways, authentication providers or remote CLIs.

## Authoritative sources checked 2026-09-11

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
