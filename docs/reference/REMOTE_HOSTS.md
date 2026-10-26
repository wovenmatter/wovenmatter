# Native Linux host workspaces

Host workspaces run Woven Matter directly on a Linux machine in the user's
Tailnet. The Mac discovers, inspects, installs and manages the service through
the same verified Tailscale SSH transport used by container workspaces. Docker
is not required. Native hosts supersede deprecated remote container workspaces,
which are no longer offered or reconnected. The separate Docker Executor is unchanged.

## Execution and permissions

The service, browser and harness CLIs run as the selected non-root SSH account.
Keeping that account's home preserves its existing CLI installations and sign-ins.
No account credentials are copied between users. There is one native workspace
per host and SSH account. Unrelated containers may continue running on the host.

The access choice applies to the whole workspace and is fixed at creation:

- **Full root** grants agents unrestricted administrative capability through
  the account's existing passwordless sudo policy. Inspection proves that a
  noninteractive root shell works. Woven does not grant sudo rights or require
  approval for each administrative operation. Full-access harness permission
  defaults are used for this workspace.
- **Normal user** uses ordinary account permissions and the harness's normal
  permission choices. The service and SSH execution wrapper set
  `no_new_privs` to block direct setuid/capability elevation. This is not an
  isolation boundary against other processes belonging to the same account:
  the account's existing operating-system authority still matters.

Neither mode imposes additional project-folder restrictions. Create folders
under Woven's managed root, link existing accessible directories, or start
folderless chats in the workspace's scratch area. Linking a folder does not
grant or revoke Linux permissions.

Creation requires acknowledging this warning, also shown in settings:

> Host mode runs agents as <user>@<host> with that user's full permissions. There is no container isolation.

## Requirements and preparation

Supported architectures are amd64 and arm64. A working systemd user manager,
Python 3, Tailscale, existing SSH authentication and trusted host keys are
required. Hosts without a systemd user manager report a blocker. Inspection is
read-only and reports missing packages, linger, available sudo, browser policy,
installed harnesses, free disk and the exact privileged preparation commands.

Preparation is the only installer operation that changes the system using
sudo. The Mac shows its commands before authorization. It can enable linger,
install browser libraries and util-linux, and load a user-specific Chromium
AppArmor allowance. It never changes SSH authentication, shell startup files,
sudo policy or the AppArmor user-namespace sysctl.

| Distribution | Package preparation | Browser namespace policy |
| --- | --- | --- |
| Ubuntu 22.04 | APT browser libraries and util-linux | Existing kernel policy |
| Ubuntu with restricted unprivileged user namespaces | APT, including current t64 package names where required | User-specific Chromium AppArmor allowance |
| Debian 12/13 | APT, with t64 names on Debian 13 | Existing kernel policy |
| Arch / Omarchy | `pacman -S --needed` for missing dependencies | Existing kernel policy |
| Other Linux distributions | Packages are operator-managed; reported as best-effort | Browser self-test must still pass |

The package records are in `remote/host/deps/`. Preparation runs only commands
reported by inspection: `loginctl enable-linger USER`, the appropriate APT or
pacman commands for missing packages, and, when necessary, installation and
`apparmor_parser -r` of `/etc/apparmor.d/wovenmatter-chromium-UID`. When private
Serve needs it, preparation also runs `tailscale set --operator=USER` through
sudo. Inspection checks the actual operator identity rather than assuming
readable Serve status permits configuration changes.
The AppArmor template covers versioned managed browser paths, so ordinary
browser updates do not require a new privileged allowance.

## Installation and layout

The Mac sends a deterministic source archive and a manifest containing every
file's digest and deployment identity. The host validates names, file types,
sizes and hashes before extracting. Pinned Node archives are verified against
the committed SHA-256 values. The locked npm graph is installed with
`npm ci --omit=dev --ignore-scripts` **on Linux**, so optional native SDKs match
the target architecture instead of the Mac. Playwright's version must match
`default-agent/package-lock.json`.

Each candidate release also has private npm tooling with the same security
floor and frozen vendor replacements used by the image build. Host maintenance
invokes that npm with the pinned Node explicitly, and SDK updates bind to the
same tooling. System npm and the shared verified Node archive are untouched;
rolling back `current` restores the prior release's private tooling.

All paths below belong to the SSH account. Managed private directories use
0700; `service.env` uses 0600.

```text
~/.local/share/wovenmatter/
  releases/<fingerprint>/        verified service and locked dependencies
  current -> releases/<fingerprint>
  node/<version>/
  node/current -> <version>
  browsers/playwright-<version>/
  browsers/current -> playwright-<version>
  browser-profiles/<profile>/
  workspace/                    managed projects and scratch chats
    .wovenmatter/               durable execution, outbox and agent state
  databases/                    managed SQLite dataset files
  run/                          runtime maintenance lock and browser result
  installation.json            workspace identity, port and runtime versions
~/.config/wovenmatter/service.env
~/.config/systemd/user/wovenmatter.service
```

The port is chosen once, beginning at the requested loopback port, and retained
on updates. A second workspace identity cannot replace an existing native
installation. The Mac obtains actual workspace, attachment and database paths
from inspection/status/health instead of assuming container paths.

`service.env` records runtime kind, access mode, workspace/data/state/profile
directories, the managed browser cache, loopback address and port, API token,
service fingerprint, discovered harness PATH, managed agent directory and PATH.
Values use literal quoted encoding. `wm-exec` parses them without executing
shell text and exports only its explicit service/harness allowlist. Tokens
travel on stdin and in the private environment file, never command arguments.

The user unit executes the pinned Node runtime and current `src/server.mjs`,
with `Restart=always`, `RestartSec=3`, `UMask=0077`, `LimitCORE=0` and
`WantedBy=default.target`. `NoNewPrivileges=yes` applies in Normal user mode;
Full root uses `NoNewPrivileges=no` so agents can invoke existing sudo.
The browser itself remains a non-root sandboxed process in both modes.

## Existing tools and accounts

Inspection discovers binaries in standard user paths, mise/asdf shims, nvm
installations and system locations without sourcing login shells. Managed
user paths take precedence. Pre-existing binaries are reported as installed
on the host and are not overwritten or updated by Woven maintenance. Woven
records ownership only for components it installs itself.

An existing sign-in CLI plus a missing ACP adapter needs only the adapter;
Woven does not rerun the CLI installer. Missing tools can be installed during
setup or later from Settings. Sign-in uses the existing authentication relay,
and the user completes any required authentication. Install/update guards
restore changed shell startup files and reject installation; recursive checks
detect changes to existing harness configuration without reporting its contents.

## Browser and profiles

Host browsing uses native headless Chromium with its sandbox explicitly
enabled. No display server or Docker container is used. Each browser profile
has its own private persistent directory; IDs contain 1–32 lowercase letters,
digits or hyphens. `default` is implicit. Browser APIs and the `woven_browser`
MCP tool accept an optional `profile`. Existing single-profile browser data is
retained as `default`. The Mac shows a profile selector when multiple profiles
exist.

Installation and updates must pass `browser-selftest.mjs --json`. The test
launches with production options, loads a local data page, obtains actual
browser/renderer PIDs through CDP and checks renderer ancestry, separate user
and PID namespaces, seccomp filtering, no-new-privileges and non-root identity.
Unreadable or inconclusive evidence fails the check. Missing libraries and
AppArmor/user-namespace failures have explicit reasons and repair hints.
Administrators can rerun the same check through `/v1/browser/selftest`.

CDP stays on host loopback. Chromium's renderer sandbox does not contain agent
shell commands or promise protection from every browser vulnerability. Browser
profiles separate website state, not Linux execution permissions.

The deprecated container workspace helpers are no longer accessible through the
remote workspace UI. Native hosts never fall back to a container or an
unsandboxed browser.

## Persistence, updates and removal

See [validation and manual review](REMOTE_HOST_VALIDATION.md) for reproducible
provider-free tests, actual workstation evidence and untested configurations.

The existing SQLite execution owner, durable relays, publisher and outbox
continue to own work on Linux. Dropping the Mac connection does not move
execution to the Mac or replay an accepted prompt. On reconnection, persisted
events synchronize through the existing protocol. Linger keeps the service
available without an interactive login. Project files themselves are not
automatically synchronized to the Mac.

Updates stage a verified release and dependencies before activation. The
installer saves prior runtime links, service environment, unit and installation
record. Failed health or sandbox verification restores the previous activation
and service state. Updates preserve managed projects, databases, browser
profiles and durable execution data.

Start, Stop, Restart and Logs use the user service and journal. Uninstall
disables the unit and removes service releases; removing data is a separate
explicit choice. Existing user-managed CLI installations and their accounts
are outside the managed data root and are preserved. Back up project files
and the complete managed data directory before intentional data removal.

Private execution sharing continues to use Tailscale Serve with the expected
loopback target; Funnel/public exposure is refused. No listener is opened on
the host's public or Tailnet interface.
