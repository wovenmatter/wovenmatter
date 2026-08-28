# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not
open a public issue for an unpatched vulnerability or include live credentials,
tokens, private hostnames, or provider transcripts in a report.

Include the affected commit, reproduction conditions, expected impact, and the
smallest safe proof of concept. Maintainers will acknowledge a complete report,
coordinate remediation, and disclose it after a fix is available.

## Supported versions

Until a stable release line exists, security fixes target the current `main`
branch. Older source snapshots and locally modified builds are not supported.

## Security boundaries

- Remote control traffic is token-authenticated and carried through an
  app-managed SSH tunnel to a host-loopback port.
- Remote tokens are stored in the macOS Keychain, not project files.
- Harness credentials remain in the applicable local or persistent remote home.
- Automated tests must not require provider credentials or make real model calls.
