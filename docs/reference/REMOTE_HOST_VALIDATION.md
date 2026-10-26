# Native host validation

Validation uses a disposable native workspace launched from the Mac through
`RemoteWorkspaceSSHClient`, the same deployment client used by Settings. Linux
is the execution destination; development and deployment remain on the Mac.
Tests do not call model providers, initiate authentication, or dispatch CI.

## Reproduce the deployed checks

Use an existing authenticated Tailnet SSH connection to a regular Linux
account. Full root requires that account's existing unrestricted passwordless
sudo policy. The opt-in Swift test generates an administrative credential,
saves it only in a private local fixture, and sends it on stdin:

```sh
WOVENMATTER_LIVE_HOST=YOUR_TAILNET_HOST \
WOVENMATTER_LIVE_HOST_USER=YOUR_LINUX_USER \
WOVENMATTER_LIVE_HOST_PREPARE=1 \
swift test --force-resolved-versions --package-path app \
  --filter RemoteHostLiveValidationTests
```

The test prints the exact required preparation actions before running them.
Use a disposable workspace, not an existing library host. By default its ID is
`host-mode-validation`. The optional rollback experiment is intentionally
restricted to the designated development validation host and that workspace ID:
set `WOVENMATTER_LIVE_HOST_ROLLBACK=1` to stage a valid candidate whose browser
check deliberately fails. Its source is assembled in a temporary directory;
the repository's browser code is not modified.

The same test covers real attachment upload, reuse, corruption repair and
Library download. Rollback compares the original fingerprint, port, paths,
runtime links, private environment, user unit, installation record and browser
diagnostics. It repairs the test installation if a deliberately failed
candidate is unexpectedly accepted.

On the deployed Linux host, run this repository's helper through the verified
Tailnet SSH transport:

```sh
scripts/test-remote-host.sh --installed host-mode-validation --offline-sync
```

It checks the actual Chromium sandbox, separate browser profiles, Full root
execution, service restart, linger, private filesystem permissions, absence of
the service credential in process arguments/journals, and an isolated SQLite
publisher outbox surviving disconnect, restart, replay and acknowledgement.
It also exercises Normal user execution through the production wrapper with a
temporary HOME, verifying its UID, no-new-privileges and refusal of direct sudo
without changing the installed workspace's access mode.

`remote/test-support/host-smoke.mjs` additionally exercises administrative versus
scoped device authority, device revocation, managed projects/datasets, snapshots,
browser storage isolation, shared MCP/viewer tabs, input, screenshots and the
live frame stream. Its private public-ID receipt can be checked after replacing
the Mac tunnel, restarting or updating the service. A separate
`--durable-fixture /absolute/path/to/src/server.mjs` mode runs the real service
with a temporary HOME and fake ACP harness on Linux, covering external project
directories, idempotent delivery, disconnect continuation, reattachment,
replacement-client fencing and restart recovery without replaying prompts.

## Evidence and boundaries

The development validation host is an amd64 Arch/Omarchy machine with a working
systemd user manager. The Mac deployed the source bundle, selected an available
non-default loopback port, connected through the production Tailnet tunnel and
verified the installed fingerprint. Node and Playwright selections come from
the committed runtime records.

The remote Node suite passed all 209 tests on Linux; macOS passed 208 with one
Linux-only skip. The final focused native Swift suites passed 99 tests, host
lifecycle/bundle fixtures passed all 24 checks, and ShellCheck passed. The broad
local validation also passed desktop source validation and package suites before
iOS simulator tests were blocked by Xcode's `DTServiceHubClient failed to bless
service hub` environment failure. Those simulator tests remain unpassed.

Observed checks include:

- Native headless Chromium: actual CDP renderer IDs, distinct user/PID
  namespaces, seccomp filtering, no-new-privileges, non-root identity and
  ancestry. Verification handles Chromium's rewritten process titles.
- Existing signed-in CLI reuse and installation of only the missing Codex and
  Claude ACP adapters. Codex readiness uses stable ACP v1 and retains stdin
  until initialization completes, matching the actual installed adapter.
- Foreground, recovered and scheduled Full root permission policy, with
  provider-free peers proving old restrictive defaults cannot reintroduce
  operation approvals.
- Private source verification, archive attack rejection, target-native locked
  dependencies, explicit private npm tooling, shell configuration protection,
  source ownership and atomic rollback fixtures.
- Mac source compilation, signed native Dev app launch and inspection of actual
  Tailnet discovery, preflight, workspace access choices and host notice.
- Deployment using the signed Dev app's actual packaged resources, followed by
  attachment transfer and persistence checks. Uninstall with retained data,
  reinstall and state recovery succeeded. Final uninstall removed the disposable
  workspace service/data and only its private Serve route.

Live model completions and fresh authentication are left to the reviewer's
manual test. Ubuntu/Debian preparation, arm64 selection and AppArmor behavior
have fixture/source coverage; fresh machines in those configurations were not
used in this workstation run. Service restart and linger were verified; the
shared development workstation was not rebooted. These boundaries must not be
reported as successful live distro, reboot or provider tests.

## Manual review

Build an isolated Dev app with `scripts/build_and_run.sh --mode snapshot` and
open Settings → Remote Agent Workspaces. Inspect the Linux host, choose the
workspace-wide access level, acknowledge the permission notice and create the
workspace. Verify existing accounts and missing-component installation. Create
a managed folder, link an existing host repository and start a folderless chat.
Then send real messages with the desired harnesses, open the shared browser,
disconnect/reconnect the Mac, and confirm updates preserve the work.
