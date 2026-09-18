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
