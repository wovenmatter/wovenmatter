# Runtime installation and updates

Technical reference. For everyday setup, start with [Agent setup](guide/agents.md).

## Runtime controls

Each page under **Settings → Agents** shows the executable and components used
by that harness. Missing components show **Install**; verified installations
appear in the sidebar automatically. Codex, Claude Code, and Grok Build sign in
inside Settings: the harness's own command runs in the background and its sign-in
link and one-time code (`codex login --device-auth`, `grok login --device-auth`) or
Claude's browser sign-in, with a field for the page's code, appear under the account.
The account shows its name or email with **Remove account**, which runs the harness's
own logout. OpenCode adds keys with its own picker in Terminal and removes each saved
key individually (`opencode auth logout <integration> <label>`). Remote workspaces use
the same panel with each harness's headless sign-in and a `/harnesses/:id/sign-out`
route.
Opening settings refreshes the inventory and available versions, without a
repeating timer. **Settings → Agents → Set up harnesses** reopens the first-launch
guide, including optional Pi Durable provider and Exa setup. The provider page
contains only OpenAI, Anthropic, Grok, OpenRouter, and OpenCode; the web-search
page contains the Exa key form. Both are also available from
**Settings → Subscriptions & API Keys**.

**Check for updates** reports available versions. **Update** installs an observed
update. Network failures leave the latest version unknown. Both actions remain
available for retry after a failure. After two failures in an app session,
**Copy diagnostic** offers component versions and an error category without raw
command output, account data, paths, or credentials.

## Components and updates

Each harness on this Mac is the person's own native CLI, in the place its vendor's
official installer puts it, so the terminal and Woven Matter run the same CLI with
the same sign-ins, skills and sessions. Woven Matter finds that install before any
other copy on the search path; its own `Node Tools/bin` holds only the ACP
adapters. Each CLI is
compared with the release channel its vendor's installer and update command read.

| Harness | Native CLI (official installer) | Woven Matter connects through | Update |
| --- | --- | --- | --- |
| Codex | `~/.local/bin/codex` ([installer](https://chatgpt.com/codex/install.sh)) | `codex-acp`, with `CODEX_PATH` set to the native CLI | `codex update` |
| Claude Code | `~/.local/bin/claude` ([installer](https://claude.ai/install.sh)) | `claude-agent-acp`, with `CLAUDE_CODE_EXECUTABLE` set to the native CLI | `claude update` |
| Grok Build | `~/.grok/bin/grok` ([installer](https://x.ai/cli/install.sh)) | Grok's own ACP (`grok … agent stdio`) | `grok update` |
| OpenCode | v2 only, `~/.opencode/bin/opencode` ([installer](https://opencode.ai/v2/install)) | OpenCode's shared background service | `opencode upgrade`, then `opencode service restart` |

## Local installation

**Install** runs the vendor's official installer for a CLI that isn't on this Mac,
downloaded from the fixed HTTPS address in `harnesses/catalog.json`, with no review
step and never through npm. An existing CLI that runs is kept as it is. Codex and
Claude Code then get their ACP adapter, which is Woven Matter's own: the latest
release installs exactly as published with Woven Matter's npm into
`Node Tools/Installations/<generation>`, is verified, and replaces the launcher
symlink in `Node Tools/bin` atomically. The generation it replaced is then deleted,
even if a running chat still uses it; a failed install leaves the working one in
place.

OpenCode 2's installer writes the same `opencode` command OpenCode 1 uses. When
OpenCode 1 is installed and OpenCode 2 isn't, Woven Matter asks before installing
(**Replace OpenCode 1?**); OpenCode's settings and data are kept. Woven Matter
starts OpenCode's shared service with `opencode service start`, so OpenCode owns it:
the `opencode` command, OpenCode's desktop app and Woven Matter use the same server,
and it keeps running when Woven Matter quits.

**Update** runs each vendor's own update command (above) in the person's login shell
with no window, so it updates the install their terminal uses however it was
installed. Each command has a ten-minute limit. A CLI is never updated while its own
sign-in is running; other harnesses go ahead. Afterwards Woven Matter reads the
versions again: the CLI must have moved to a newer version (a vendor's native channel
can trail the newest registry publication, so it needn't reach it), and the adapter
must reach its target. An update that changed nothing reports
that it finished without updating. Nothing updates automatically.

Subprocesses have a bounded duration and their own process group, so a timed-out
shell's children cannot continue an installation after retry becomes available.
Different harnesses update at the same time, in Settings → Updates and here. Each
harness keeps its own progress, failure, and installation lock; duplicate operations
on the same harness are rejected. New local message sends and maintenance actions are
mutually gated during a local runtime operation. No operation cancels an active turn.

## Remote installation

Each Linux host has its own inventory, preferences, latest checks and verified
maintenance actions, served by the host's service. The Mac that installed the
host reaches them through an SSH tunnel with the host's API token. Installers
execute on the selected host.
Local package presence never verifies a remote
installation or a linked gateway's runtime.

Each harness on a host is the host user's own native CLI, so someone who opens a
terminal there uses the same CLI, sign-ins, skills and sessions as Woven:

| Harness | Native CLI (official installer) | Woven connects through | Update |
| --- | --- | --- | --- |
| Codex | `~/.local/bin/codex` ([installer](https://chatgpt.com/codex/install.sh)) | `codex-acp`, with `CODEX_PATH` set to the native CLI | `codex update` |
| Claude Code | `~/.local/bin/claude` ([installer](https://claude.ai/install.sh)) | `claude-agent-acp`, with `CLAUDE_CODE_EXECUTABLE` set to the native CLI | `claude update` |
| Grok Build | `~/.grok/bin/grok` ([installer](https://x.ai/cli/install.sh)) | Grok's own ACP (`grok agent stdio`) | `grok update` |
| OpenCode | v2 only, `~/.opencode/bin/opencode` ([installer](https://opencode.ai/v2/install)) | OpenCode's shared background service | `opencode upgrade`, then `opencode service restart` |

A missing CLI is installed by downloading its vendor's official installer from that
fixed HTTPS address and running it, with no review step and never through npm.
The installers may add their folder to the user's shell startup files, as they do
for anyone; Woven's harness PATH already includes those folders. When the CLI is
present and only its ACP adapter is missing, only the adapter is installed. The
adapters are Woven's own: they install with the host's npm into
`~/.local/share/wovenmatter/acp-adapters` and are updated there when a newer one is
published; as on a Mac, the replaced copy is deleted once the new one is verified. A CLI in the user's home is reported with `source: "native"` and is
updated with its vendor's command; one outside it (a distribution package) is
`system` and is left alone; Woven's adapters are `managed`.

An update runs the vendor's command in the background with the harness environment,
stops it after three minutes, and succeeds only when every component that was behind
reaches the checked version. An updater that exits 0 without changing the version is
reported as a failed update. Each harness has its own maintenance lock
(`runtime-operation-<id>.lock`), so different harnesses install and update side by
side. Active Woven sessions on a harness block its maintenance until they finish.

OpenCode v1 and v2 share the `opencode` command, and the official v2 installer
replaces v1's. When a host has OpenCode v1 and no v2, its inventory reports
`openCodeV1: { path, version }` and an install fails with
`opencode_v1_replacement_confirmation_required` until the app sends
`replaceOpenCodeV1: true` after the user agrees. Their data is kept.

Install and update take `{ "confirmed": true }` and start at once; nothing is
previewed first.

## Service controls

OpenCode settings open the selected workspace's server and model settings. On a host,
Woven uses OpenCode's one shared background service for the host user, the same one
`opencode` in a terminal and the desktop app use: it starts it with
`opencode service start`, stops it with `opencode service stop`, restarts it onto a
new release after an upgrade, and finds it through OpenCode's own
`~/.local/state/opencode/service.json`. The service keeps running when Woven stops.
The app routes requests and event streams to the host's member proxy, which accepts
requests signed with the Mac's device key over the tailnet. The service's Basic
credential stays on the remote host; no public OpenCode listener or remote browser
credential URL is created.

## Upstream reference snapshot — September 11, 2026

For the app's declared
packages and checks, use [the harness catalog](../harnesses/catalog.json),
[local maintenance](../app/Sources/WovenMatterClient/RuntimeMaintenance.swift),
and [remote maintenance](../remote/src/runtime-maintenance.mjs).

- [Codex adapter](https://github.com/agentclientprotocol/codex-acp) and
  [npm metadata](https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest):
  each release declares its `@openai/codex` range.
- [Claude adapter](https://github.com/agentclientprotocol/claude-agent-acp) and
  [npm metadata](https://registry.npmjs.org/@agentclientprotocol%2fclaude-agent-acp/latest):
  each release declares its Claude Agent SDK range.
- [OpenCode package](https://registry.npmjs.org/@opencode%2fcli/latest): the current
  stable v2 release; each install/update resolves this tag afresh.
- [Grok CLI reference](https://docs.x.ai/build/cli/reference) and
  [official installer](https://x.ai/cli/install.sh).
