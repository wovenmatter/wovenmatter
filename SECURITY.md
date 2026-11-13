# Security policy

## Reporting a problem

Open an [issue](https://github.com/wovenmatter/wovenmatter/issues) describing
the problem. Include the affected version or commit, how to reproduce it, and
the impact you expect. Do not include live credentials, tokens, signing keys,
private hostnames, or provider transcripts in an issue. If a report needs
details that should not be public, email
[security@wovenmatter.com](mailto:security@wovenmatter.com) and say so in the
issue.

## Supported versions

Security fixes go into `main` and ship in the next release. Only the latest
published release is supported. Older releases, source snapshots, and locally
modified builds are not.

## How Woven Matter is secured

### Devices and requests

- Each Mac, Linux host, and iPhone has its own long-lived signing key: in the
  Keychain on Apple devices, and in a `0600` file on Linux.
- The member list is a signed record set that syncs to every device. Pairing a
  device adds it; removing a device is a signed revocation that takes effect on
  each device as soon as that device syncs.
- Requests between devices are signed with the caller's device key and carry
  no reusable session token. They travel over the user's own Tailscale
  network as tailnet HTTPS (`*.ts.net`). Live session streams use a WebSocket
  signed the same way.
- A Mac installs and maintains a Linux host over Tailscale SSH, using the
  account's existing OpenSSH authentication and trusted host keys.

### Agents

- New conversations start in **Full access** on every workspace, including
  sessions started by other agents. Full access lets a harness run commands and
  edit files without ordinary approval prompts, within that harness's own
  enforced policy. Choose a stricter policy per conversation where the harness
  offers one.
- Woven-launched sessions reach Woven MCP with credentials bound to their
  conversation. **Outside agents** exposure starts off. When it is on, any agent
  that your tailnet policy allows to reach the displayed endpoint can use the
  enabled tool groups, including writes, without a separate token.
- Third-party harness credentials stay in each harness's own home on the
  machine that runs it; Woven Matter does not read or change their auth files.
  Pi Durable provider credentials are kept in the Mac's Keychain and reach
  Linux hosts only in encrypted form. See
  [default agent credentials](docs/architecture/DEFAULT_AGENT_CREDENTIALS.md).
- Computer Use and other access to the Mac (Keychain, Full Disk Access,
  Accessibility, Screen Recording, Automation, Microphone) need the matching
  grant in **Settings → Permissions & Access**.

### Bots

- Each bot runs its tools in its own container. Containers have internet
  access but cannot reach the tailnet, private networks, the host, or each
  other.
- Provider credentials never enter a container. Each bot has its own Woven MCP
  key, which can be revoked per bot.

### Updates

- Mac releases are signed and notarized. The update feed and each update
  archive are also signed with a dedicated Ed25519 key that the app checks
  before installing.
- Bundled runtimes and downloaded components are pinned with checksums or
  signatures recorded in the repository. See the
  [dependency policy](docs/DEPENDENCIES.md).

### Tests

Automated tests do not use provider credentials or make real model calls.
