# Agent setup

An **agent runtime** (also called a harness) is the software that does the work;
a **provider** supplies the model and account access. Woven Matter connects to
these runtimes and presents their conversations in one app.

## Choose and enable a runtime

Open **Settings → Local agent workspace**, or choose a workspace under
**Remote agent workspaces**. Install a missing runtime, enable it, and complete
its own authentication or connection flow. Setup checks installation,
connection readiness, and account access separately.

| Runtime | Connection in Woven Matter |
| --- | --- |
| Codex | Codex with its ACP adapter |
| Claude Code | Claude Code with its ACP adapter |
| Grok Build | Native agent-stdio transport |
| Cursor | Native ACP transport |
| Pi | Native RPC transport |
| Hermes | Native Hermes server with agent and session settings |
| OpenCode | Supported OpenCode v2 service with model and server settings |
| OpenClaw | Agent and Gateway settings; ACP is also used during setup |

The app offers the methods supported by the selected integration. Existing
provider access may be discovered where supported; installing a runtime does
not grant access to a model or copy a Mac login to a remote machine. Provider
billing and account limits apply to your usage.

OpenCode uses a specific supported v2 build. Use the app's installation flow;
an arbitrary newer release or an older OpenCode CLI is not interchangeable.
Hermes, OpenCode, and OpenClaw have service controls beyond the basic runtime row.
Stopping a shared service can affect other clients using it.

## Keep runtimes current

Use **Check for updates** or **Update** in the workspace's runtime row. Checking
does not install an update. Finish active work before updating; a busy runtime
may block maintenance. A remote update applies to the selected workspace.

**Hide** controls visibility; **Disable** controls whether the integration is
enabled. Neither should be treated as uninstalling software or deleting its data.
For OpenCode, disabling disconnects the app without stopping the shared server;
use its server controls when that is your intent.

Third-party runtimes and adapters are installed on request, not bundled in the
remote image. For component versions and maintenance details, see
[Runtime maintenance](../RUNTIME_MAINTENANCE.md).
