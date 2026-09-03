# WovenMatter

[![Download WovenMatter for Apple silicon](https://img.shields.io/badge/Download-WovenMatter_for_Apple_silicon-000000?logo=apple&logoColor=white)](https://github.com/wovenmatter/wovenmatter/releases/download/v0.1.0/WovenMatter_0.1.0_arm64.dmg)

WovenMatter is a native macOS workspace for coding agents. It keeps notes,
conversations, runs, and agent sessions in a local SQLite store while giving
supported harnesses one shared workspace rooted at `~/.woven-matter`.

The app is useful on its own. Buzz discovery is an optional, disabled-by-default
local feature. Remote workspaces are optional standalone Linux containers,
created and controlled over the user's existing SSH configuration.

## What v0.1 includes

- Native SwiftUI workspace, notes, databases, usage views, and direct chats.
- The shared Codex, Claude Code, Grok Build, Hermes, Cursor, OpenCode, Pi, and
  OpenClaw harness catalog.
- Optional discovery and conversations for Buzz workspaces already on this Mac.
- Multiple independent remote workspace containers on one or more Linux hosts.
- Install, authentication, update, health, lifecycle, and resource controls for
  remote workspaces.
- OpenClaw ACP bootstrap plus authenticated Gateway connectivity for sessions,
  events, models, attachments, cron, and heartbeat behavior.

Every local or remote workspace begins with the same relative layout:

```text
.woven-matter/
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  REPOS/
  Databases/
  GUIDES/
  PLANS/
  RESEARCH/
  WORK_LOGS/
  OUTBOX/
  .scratch/
```

Users and agents can change the contents after initialization.

## Requirements

- macOS 26 and Xcode 26 for the native app.
- Node.js 24 for remote-service tests.
- A reachable amd64 or arm64 Linux host for remote workspaces. Docker may
  already be present; authorized automatic Docker Engine preparation is
  currently supported on Ubuntu and Debian.
- OpenSSH configuration and an SSH agent that can reach each remote host.
- Bash and standard Linux disk-usage tools on the remote host. Normal lifecycle
  operations do not require host copies of `jq`, Node.js, npm, or the workspace
  harnesses.
- Tailscale is optional; when installed, the app can offer reachable Tailnet
  machines in addition to manual hostname entry.

No provider credentials are needed to build or test the project. Harnesses are
installed only after a user chooses to install them, and authentication remains
inside each local or remote user environment.

## Development

Build and launch the development app with stable caches under `/private/tmp`:

```sh
scripts/build_and_run.sh
```

Run the complete deterministic validation suite:

```sh
scripts/test-changes.sh --all
```

Run the container lifecycle smoke test when Docker is available:

```sh
scripts/test-container.sh
```

The Xcode project is `app/WovenMatter.xcodeproj`; the dependency-free Swift
package is rooted at `app/`. Development scripts do not publish, install, or
notarize an app. Production releases are Apple Silicon builds from reviewed
and merged source, published as versioned GitHub Release assets named
`WovenMatter_X.Y.Z_arm64.dmg`.

Validation behavior lives in repository-owned scripts. See
[docs/MAINTAINER_WORKFLOW.md](docs/MAINTAINER_WORKFLOW.md) for the continuous
integration policy and the development, staging, and release environment
boundaries.

## Remote workspaces

In Settings, choose Remote Workspaces, select a discovered Tailnet machine or
enter a hostname, and create a workspace. Woven Matter uses an explicit
inspect → explain → authorize → prepare → verify → create workflow. Inspection
does not install packages or change configuration. If preparation is needed,
the app lists each supported change and requires confirmation before applying
it, then repeats inspection before provisioning anything.

Automatic preparation uses Docker's official apt repository on Ubuntu and
Debian. Woven Matter does not remove conflicting container packages, add the
SSH account to the root-equivalent `docker` group, or use Docker's convenience
installer. Existing compatible Docker Engines on other Linux distributions
remain supported. When direct Docker access is unavailable, Woven Matter can
use an existing root login or passwordless sudo policy rather than changing
group membership. OpenSSH continues to resolve hosts, users, agents, and keys;
the app does not maintain a separate SSH credential store.

The control API is token-authenticated. Docker publishes it only on
`127.0.0.1` of the Linux host, and the app reaches it through an SSH tunnel.
Each container runs as a non-root user with a read-only root filesystem,
dropped capabilities, bounded temporary filesystems, and a dedicated persistent
Docker named volume mounted at `/home`. The container user's home is `/home`,
and the Woven Matter workspace is `/home/.woven-matter`; installed harnesses,
configuration, credentials, and caches also persist under `/home`. Its base
image is pinned by multi-architecture manifest digest,
and its local log driver rotates bounded files. Container updates use a rollback
container and preserve the prior running state if the replacement does not
become healthy. Deleting a container and deleting its data are separate actions.

Docker enforces the RAM ceiling. The app treats Swap as additional to RAM and
translates the two values to Docker's combined `--memory-swap` value. For
example, 8 GiB RAM plus 4 GiB Swap becomes a 12 GiB combined ceiling.

Workspace storage has no fixed size limit and uses the available capacity of
the remote host filesystem backing Docker's volume. Woven Matter reports each
workspace's current usage together with host capacity and available space, and
shows a non-blocking warning when that host filesystem is running low. If those
values cannot be measured safely with the existing Docker and standard Linux
tools, the app reports them as unavailable instead of launching helper
containers or installing measurement packages. In particular, usage for a
stopped named-volume workspace is unavailable because Woven Matter does not
start a measurement container or access Docker-managed volume contents directly.

Container removal and data removal remain separate actions. Restarting,
updating, or recreating a workspace preserves its named volume. Woven Matter
removes that volume only after the user explicitly chooses to remove persistent
data. Legacy workspaces using a different storage layout remain detectable and
readable; their data is never silently moved or deleted, and recreation requires
an explicit migration.

`remote/compose.yaml` is a reviewable single-workspace example. The app uses
`scripts/remote-workspace.sh` for lifecycle operations so several independently
named workspaces can coexist.

## Harness setup

Settings reports installation, transport readiness, and authentication
separately. Every supported harness follows the same first-class flow: install,
discover reusable provider access, choose a native account or API-key method,
and verify the harness's own authentication state. Pi offers Codex, Grok, or
API-key setup. Hermes and OpenClaw detect provider access they can safely reuse
and otherwise offer their native provider flows. OpenCode supports the OpenCode
Go account flow. There is no embedded setup terminal, synthetic readiness
marker, agent-mediated setup chat, or generic command-input surface. Installs
and credentials live in the workspace home and survive container recreation.

Third-party CLIs and separate ACP adapters are not bundled in the container
image. Their commands and sources are declared in `harnesses/catalog.json` and
run only after explicit user action. Native ACP, agent-stdio, Gateway, and Pi RPC
transports are checked after installation instead of being assumed present.

## Limitations

- Remote workspaces require a reachable Linux Docker host.
- Remote local-file attachments must first be added to the remote workspace;
  a Mac path is not silently copied into a container.
- Workspace storage has no fixed limit. The remote host must retain enough free
  space for workspace files, installed harnesses, credentials, and caches.
- Automatic runtime installation is limited to supported Ubuntu and Debian
  releases with root SSH or passwordless sudo and no conflicting container
  packages. Other hosts receive an exact manual-preparation blocker.
- Provider sign-in and real model calls require the user's own accounts and are
  intentionally excluded from deterministic validation.
- Harness installers are fetched from their declared upstream URLs only after
  user approval; their contents are not pinned and may change independently of
  Woven Matter.
- Distribution signing and notarization require maintainer-controlled Apple
  credentials. A `vX.Y.Z` tag runs the release workflow and stages its verified
  assets in a private draft. Publication is a separate, explicitly confirmed
  action restricted to the repository owner.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before contributing or
redistributing the app.
