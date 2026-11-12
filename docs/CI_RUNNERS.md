# Owned CI runners

Manual validation and releases run on two machines Trey owns instead of GitHub's
hosted runners. GitHub still schedules the jobs, shows their logs, keeps secrets
and artifacts, and runs the small jobs listed below.

| Label | Machine | Runs |
| --- | --- | --- |
| `wovenmatter-macos` | The Apple Silicon Mac mini, in Trey's logged-in session | Desktop and mobile validation, the signed release build |
| `wovenmatter-linux` | Trey's x86_64 Linux workstation, as a systemd user service | Portable and Linux validation, the release gate, the Linux library release binaries |

Each machine runs one job at a time, so jobs for the same machine wait their
turn. A release can wait behind a validation run that started first.

## What stays on GitHub's runners

- **PR CI (`ci.yml`), the PR author label and analytics.** Anyone can open a
  pull request on this public repository. Running fork code on a persistent
  machine is unsafe, and these jobs are small and reliable where they are.
- **The `images` validation scope.** Its arm64 image needs arm64 Linux hardware.
  It also tags images such as `wovenmatter/workspace:latest`, which a shared
  Docker host would see.
- **The update-refresh dispatcher (`refresh-release.yml`).** It only creates a
  tag. The signed build it starts runs here.

## Security boundary

Before every job, the runner runs `scripts/ci-runner/runner-guard.sh`. It
refuses the job unless all three of these hold:

- the repository is `wovenmatter/wovenmatter`;
- the event is `workflow_dispatch` or `push`, both of which need write access;
- the workflow is `validation.yml` or `release.yml`.

Pull requests are refused, even if a branch edits a workflow to target these
labels. The guard is copied into the runner's install directory, outside every
checkout, and reads its settings only from there. No branch or workflow can
change it.

Jobs run as Trey's user. They don't see that user's GitHub login, git config,
SSH agent, or npm and Docker credentials. The runner's environment points each
of those at empty files in `~/actions-runner/wovenmatter/isolation`. Anyone with
write access can run code here. That's the same trust already given to the
agents that work on these machines.

Caches persist between runs, under `~/Library/Caches/WovenMatterCI` on the Mac
and `~/.cache/wovenmatter-ci` on Linux. They are separate from the caches your
own dev builds use (`scripts/ci-runner/cache-env.sh`):

- Validation of any branch writes only `validation/`.
- Only release builds write `release/`, and a release builds only tagged main
  source (or a rehearsal).
- Every consumer verifies what it takes from a cache. Intermediates start fresh
  in each release job's temporary directory.

On the Mac, signing adds a temporary keychain in front of the user's keychains
and deletes it when the job ends. If a job is killed first, the guard removes
the leftover entry. The job fails if the search list has more than one
`Developer ID Application` identity, so keep that identity out of the login
keychain.

## Setup

A repository admin registers each runner once:

1. Open the repository's Settings > Actions > Runners > New self-hosted runner
   page.
2. Copy the token from its configure command. It is valid for an hour.
3. From a checkout on the Mac, run this and paste the token at the hidden prompt:

```bash
scripts/ci-runner/install-runner.sh
```

```bash
scripts/ci-runner/install-runner.sh --host workstation
```

The installer:

- downloads the current official `actions/runner` release and checks it against
  the SHA-256 published in its release notes;
- registers the runner with its label;
- installs the guard and the isolated environment;
- starts the service: a LaunchAgent on the Mac, and a lingering systemd user unit
  (`wovenmatter-actions-runner.service`) on Linux.

Re-running it refreshes the guard and environment without a token. Run it again
after changing anything in `scripts/ci-runner/`.

The machines need:

- **Mac:** the Xcode in `app/xcode-version.json`, selected with `xcode-select`;
  cmake; and the iOS simulator runtime and device types used by `validation.yml`.
- **Linux:** Docker, with the user in the `docker` group; python3, git, curl and jq.

## Upkeep

- **Runner software** updates itself, as GitHub requires.
- **Xcode** is pinned by `app/xcode-version.json`. An update on the Mac,
  including an App Store auto-update, stops the macOS jobs at their first step
  until a maintenance PR moves the record. Turn off automatic App Store updates
  for Xcode.
- **After a reboot**, log in to the Mac once. The LaunchAgent runs in that
  session, because desktop tests need the window server. The Linux service starts
  by itself.
- **If a machine is off**, its jobs wait in GitHub's queue, for up to 24 hours,
  until it is back. To move work back to hosted runners, change the `runs-on`
  labels (and the Xcode record's `runner`) in a PR.
- **To remove a runner**, run `./svc.sh uninstall` on the Mac or
  `systemctl --user disable --now wovenmatter-actions-runner` on Linux. Then run
  `./config.sh remove` in `~/actions-runner/wovenmatter` with a removal token from
  the same Settings page.

## Rehearsing a release

A rehearsal runs every release phase on these runners without publishing
anything:

- compile;
- sign and seal;
- notarize the app;
- build and sign the disk image;
- notarize the disk image;
- build the signed feed.

Use one after a runner, Xcode or release-workflow change, from any commit,
including an unmerged PR's:

```bash
git tag v-rehearsal-NAME COMMIT && git push origin v-rehearsal-NAME
```

```bash
gh workflow run release.yml --ref v-rehearsal-NAME -f rehearsal=true
```

It builds version 0.0.1, skips the validation gate, and creates no draft. It
deletes its signed output when it finishes. Delete the tag afterwards:

```bash
git push origin :refs/tags/v-rehearsal-NAME && git tag -d v-rehearsal-NAME
```
