# Remote workspace reference

For setup and everyday use, start with [Remote workspaces](../guide/remote-workspaces.md).
This page describes host preparation, isolation, storage, and lifecycle behavior.

Remote workspaces now run only as native **Linux host** services, using the SSH
account's existing tools and sign-ins. See [Native Linux hosts](REMOTE_HOSTS.md)
for the supported setup, permissions, browser verification and lifecycle.

## Deprecated container implementation

Remote container workspaces are no longer offered, managed or automatically
reconnected by the app. The remaining details below document retained internal
container helpers, not a supported setup option. This deprecation does not alter
the standalone Docker Executor or delete any host containers or data.

## Host preparation

Automatic preparation uses Docker's official apt repository on Ubuntu and
Debian. Woven Matter does not remove conflicting container packages, add the
SSH account to the root-equivalent `docker` group, or use Docker's convenience
installer. Existing compatible Docker Engines on other Linux distributions
remain supported. When direct Docker access is unavailable, Woven Matter can
use an existing root login or passwordless sudo policy rather than changing
group membership. OpenSSH continues to select users, agents, and keys; the app
does not maintain a separate SSH credential store. Docker Engine 28+ is required:
older Docker releases can expose localhost-published ports to adjacent hosts.
Keep the host OS, Docker Engine, OpenSSH, and Tailscale on current stable security
updates through the host's package manager.

## Isolation and connection

The control API is token-authenticated. Docker publishes it only on
`127.0.0.1` of the Linux host, and the app reaches it through an SSH tunnel over
Tailscale. All SSH paths (provisioning, lifecycle, tunnels, attachments, shared
files, and stdio harnesses) select an unambiguous online peer from the local
Tailscale daemon and invoke `tailscale nc` with that peer's Tailscale address.
There is no DNS/LAN or public SSH fallback. Command-line SSH options override
proxy jumps and hostname routing, disable multiplexed connection reuse, agent
forwarding, and local commands, and require an already trusted SSH host key.
HTTPS client sharing remains private Tailscale Serve with Funnel refused before
and after route configuration. The native administration client accepts only its
local loopback tunnel and refuses HTTP redirects.

Each workspace uses a dedicated NAT bridge with inter-container communication
disabled; it never joins Docker's shared default bridge. Lifecycle operations
verify container/network ownership, and starting or sharing a workspace requires
its loopback publication and private network. Existing workspace containers must
be explicitly updated to apply these settings. Each container runs as a non-root user with a read-only root filesystem,
dropped capabilities, a 512-process limit, core dumps disabled, private default
file permissions, bounded temporary filesystems with `noexec,nosuid,nodev`, and a dedicated persistent
Docker named volume mounted at `/home`. The container user's home is `/home`,
and the Woven Matter workspace is `/home/.woven-matter`; installed harnesses,
configuration, credentials, and caches also persist under `/home`. Its base image
follows the official Node slim image for the app's bundled Node stable major, and its
local log driver rotates bounded files. Container updates use a rollback
container and preserve the prior running state if the replacement does not
become healthy. API credentials are passed through an atomically created private
temporary environment file and removed after Docker reads it; they do not appear
in Docker or sudo command arguments. The service bounds HTTP headers, request
upload time, body sizes, connection counts, and keep-alive request counts. Browser
origins are refused, and unexpected server errors do not expose internal details.

The unused base-image `node` account and its private `/home/node` directory are
removed at image construction, before a fresh home volume is seeded. This keeps
the dedicated home readable by its workspace owner for storage measurement;
image construction does not modify existing persistent volumes.

## Resources and storage

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

## Image reuse and build progress

Creation checks a SHA-256 fingerprint of the bundled Docker inputs before
packing or uploading them. It reuses a Linux image only when its fingerprint
and host architecture match and it was built less than 24 hours ago. This bounds
the delay for upstream base/security updates; it is not an upstream package
check. Missing, changed, or older images rebuild with `--pull --no-cache`.
**Update container** always rebuilds, regardless of age.

Builds serialize for the SSH user and recheck after acquiring the lock. Creation
uses the resulting immutable image ID, so another build cannot change the image
between verification and container creation. The app streams named build phases
(base image, Linux dependencies, browser/agent dependencies, and image export)
without inventing a percentage or duration. A failed build leaves the previous
image available and does not create a workspace from it.

Build-time npm caches stay outside `/home` and are removed from the image.
Harness installation uses a workspace-owned npm cache so preserved homes with a
legacy root-owned `~/.npm` do not prevent adapter installation. Operation IDs are
normalized when polling installation progress.

## Updates and deletion

**Update container** rebuilds the app's bundled image definition with a fresh
APT package index and upgrades the base OS packages before installing workspace
tools. Builds use `--pull --no-cache`, so a repeated update does not reuse an old
security-package layer. Both Linux image definitions use the same
`node:<current major>-trixie-slim` multi-architecture base, so each rebuild takes the
newest Node patch of that stable major. Workspace agent dependencies install from
the committed lockfile with `npm ci`, and the workspace Playwright CLI matches
the locked `playwright-core`. The image stays read-only at runtime; OS updates
happen in the replacement image, never inside a running workspace.

Container removal and data removal remain separate actions. Restarting,
updating, or recreating a workspace preserves its named volume. Woven Matter
removes that volume only after the user explicitly chooses to remove persistent
data. Legacy workspaces using a different storage layout remain detectable and
readable; their data is never silently moved or deleted, and recreation requires
an explicit migration.

[remote/compose.yaml](../../remote/compose.yaml) is a single-workspace example.
The app uses [remote-workspace.sh](../../scripts/remote-workspace.sh) to manage
several independently named workspaces.

## Harness availability

Installed harnesses are automatically available and shown in the local and remote
workspace interfaces. Authentication and verified runtime components still gate
chat readiness; there are no separate harness enable or visibility preferences.
Old local preferences are ignored. When connecting to an older workspace image,
the Mac app clears retired hidden/disabled flags for verified installations.
New workspace services derive compatibility fields from installed components and
ignore legacy preference writes; they persist diagnostic failure counts only.
This migration does not sign in or copy credentials, start conversations, or
change the workspace's background-execution setting.

## Maintaining runtime dependencies

Dependency maintenance runs manually or through an owner-run agent task; see
[the dependency policy](../DEPENDENCIES.md). The former monolithic refresh
script has been removed. External maintenance jobs are configured separately
from repository CI.

Prepare updates on a dedicated branch based on current `main`. Review current
upstream releases, update package declarations and lockfiles through their
package managers, and keep runtime version records and archive checksums in
sync. A coordinated Pi update requires every Pi package and Chord to be
published at the same version. Regenerate affected mobile bundles and
provenance with their resource-generation scripts. Review integration changes
and record focused checks and any pending native validation in the PR.
Dependency maintenance does not deploy a host or update a running workspace.

PR CI verifies generated resources. The explicitly requested **Manual validation**
workflow (`scope=images` or `all`) builds both images on Linux. Its workspace
smoke test verifies authenticated access, per-workspace volumes,
restart/update preservation, and explicit data-deletion boundaries. Executor
image tags include the Dockerfile fingerprint, so setup replaces an old base
even when the selected Executor SDK version is unchanged; unchanged setup
retries retain the existing container. Host OS, Docker, and Tailscale maintenance
remain separate operator actions on the owning host.

## Pi Durable SDK updates

Each workspace service owns its Pi Durable SDK and Claude SDK installation.
The Pi Durable settings page groups their installed versions and update
controls beneath expandable workspace rows. **All workspaces** lists the local
installation and each configured remote workspace; choosing one workspace
limits the list to that workspace.

The token-authenticated control API exposes `GET /v1/default-agent/sdks` for
installed package metadata, without initializing an agent, unlocking credentials,
or checking the network. `POST` to the same endpoint accepts
`{"action":"check","id":"claude"}` for an explicit registry check, or
`{"action":"update","id":"claude","version":"x.y.z"}` for an update.
The SDK identifier is `pi` or `claude`; omit it from a check or update to manage both SDKs. A combined update stages all outdated components and activates them together.
The checked version is optional on updates. Responses contain `sdks` entries with `id`,
`name`, `installedVersion`, `latestVersion`, and `updateAvailable`, plus the
installation `generation` and an optional `notice`. Request bodies are bounded
to 4 KiB. Disconnection cancels work before activation; an already activated
installation remains installed.

Updates run as the existing workspace owner and persist in its named volume.
They do not modify the read-only container image or the separately installed
agent CLIs. Package installation stages an immutable generation and verifies it
before activation. Running conversations retain their generation; the service
only replaces an idle worker. Scheduled tasks hold a runtime lease from session
setup through completion so an update cannot split their model, permission,
and prompt setup between workers. Credentials and conversation files remain in
the same workspace storage.

Older workspace services that do not expose this endpoint must be updated
through the existing workspace update control before managing SDKs. Opening
SDK settings does not update or start a workspace automatically.

## Security review

Tailscale policy must grant only intended users/devices access to workspace
SSH and private HTTPS ports. A Tailnet membership alone does not establish least
privilege. Root, Docker administrators, and the workspace's SSH account remain
trusted operators; agents inside one workspace share its credentials and files.
Do not use a single workspace as an isolation boundary between untrusted users.
