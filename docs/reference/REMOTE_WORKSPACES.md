# Remote workspace reference

For setup and everyday use, start with [Remote workspaces](../guide/remote-workspaces.md).
This page describes host preparation, isolation, storage, and lifecycle behavior.

## Host preparation

Automatic preparation uses Docker's official apt repository on Ubuntu and
Debian. Woven Matter does not remove conflicting container packages, add the
SSH account to the root-equivalent `docker` group, or use Docker's convenience
installer. Existing compatible Docker Engines on other Linux distributions
remain supported. When direct Docker access is unavailable, Woven Matter can
use an existing root login or passwordless sudo policy rather than changing
group membership. OpenSSH continues to resolve hosts, users, agents, and keys;
the app does not maintain a separate SSH credential store.

## Isolation and connection

The control API is token-authenticated. Docker publishes it only on
`127.0.0.1` of the Linux host, and the app reaches it through an SSH tunnel.
Each container runs as a non-root user with a read-only root filesystem,
dropped capabilities, bounded temporary filesystems, and a dedicated persistent
Docker named volume mounted at `/home`. The container user's home is `/home`,
and the Woven Matter workspace is `/home/.woven-matter`; installed harnesses,
configuration, credentials, and caches also persist under `/home`. Its base image is pinned by a multi-architecture manifest digest, and its
local log driver rotates bounded files. Container updates use a rollback
container and preserve the prior running state if the replacement does not
become healthy.

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

## Updates and deletion

Container removal and data removal remain separate actions. Restarting,
updating, or recreating a workspace preserves its named volume. Woven Matter
removes that volume only after the user explicitly chooses to remove persistent
data. Legacy workspaces using a different storage layout remain detectable and
readable; their data is never silently moved or deleted, and recreation requires
an explicit migration.

[remote/compose.yaml](../../remote/compose.yaml) is a single-workspace example.
The app uses [remote-workspace.sh](../../scripts/remote-workspace.sh) to manage
several independently named workspaces.

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
The SDK identifier is `pi` or `claude`; omit it from a check to check both SDKs.
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
