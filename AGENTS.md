# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Never initiate or operate account login, device authorization, or authentication
  UI. Release authorization does not authorize authentication recovery. Use only
  existing credentials; never run `gh auth login`, `refresh`, `logout`, or `switch`.
  A sandboxed `gh` failure does not prove a missing or invalid credential. Retry
  the read-only `scripts/check-release-access.sh` through the approved execution
  permission path; if it still fails, stop and report the blocker to the user.
- Build and launch: `scripts/build_and_run.sh`.
- Dev builds have three modes. "Build/run this as a client", "use live data", or "use a live client"
  means `scripts/build_and_run.sh --mode client`. "Build this from a snapshot"
  or "use a snapshot" means `--mode snapshot`. "Build the live database" or "host the
  production database directly" means `--mode live`: this Dev profile’s background server becomes the
  production library host and requires its exclusive execution lease.
  If unspecified, choose client for UI, harness, tool, and instance-owned scheduling
  changes; choose snapshot for library-host, persistence/schema, protocol, or
  intentionally isolated tests. State the choice briefly and proceed without
  asking the user to choose. `--plan` prints the resolved profile without building
  or reading production data; `--mode auto` provides a conservative file-based
  fallback between client and snapshot; never select live automatically. Explicit
  user choice always wins. See [development builds](docs/DEVELOPMENT_BUILDS.md).
- Only an explicitly requested live host may open production SQLite directly.
  Stop the existing production host, including background execution, before that
  launch; never bypass the lease or force-kill an owner. Client and snapshot builds
  remain isolated. Never copy another client's credentials or silently substitute
  a snapshot when a client connection fails. Use `--instance NAME` for another instance
  of one worktree or a fresh snapshot; existing snapshots retain their edits.
- For UI work, follow [the style guide](docs/STYLE_GUIDE.md).
- Validate: `scripts/test-changes.sh`; use `--all` for changes spanning components.
  Use `--ci` for CI-only changes. Automatic PR CI is one portable Linux check;
  native/mobile/image workflows run only when explicitly requested.
  PR CI and explicitly requested platform validation own source validation.
  Release preparation never runs local test suites or reruns CI; follow the
  release skill to start the workflow.
  Tests must not consume provider services. Container lifecycle tests use
  `scripts/test-container.sh` when in scope and Docker is available.
- Release, installation, publication, and delivery require an explicit request.
  Always build and verify a private draft, then present its user-facing release
  description to Trey and wait for his explicit approval before publication.
  Version confirmation alone does not authorize publication.
  For releases, use `.agents/skills/cut-release-wovenmatter/SKILL.md`.

## Dependencies

Follow [the dependency policy](docs/DEPENDENCIES.md).

- Stay current. Declare ordinary npm dependencies with minimum-only ranges
  (`>=version`) whose floor is the tested release; newer stable majors remain
  eligible. Never leave a dependency on an old version or major without a reason.
- An exact or narrowed selection needs a concrete security or core-function
  reason, documented beside it and in `docs/DEPENDENCIES.md`. It also needs
  a documented maintenance process and a stated validation boundary.
- Lockfiles, `app/Package.resolved`, and the Node, CEF, and Sparkle records are
  required. Builds and tests consume the committed package graphs (`npm ci`)
  and native runtime records. Linux base images intentionally follow their
  current stable Node major, as documented in the policy. Change recorded
  selections through maintenance refresh and regenerate dependent provenance
  in the same change. Never hand-edit
  `app/Package.resolved`; use package-manager tooling to generate the combined
  SwiftPM/Xcode graph. Normal builds consume it with resolution frozen.
- Keep checksums, signatures, updater keys, and provenance. Keep every copy of
  one selection in sync and verify that the records agree before proposing updates.
- Read-only workflow helpers may track `@main`. Workflows with write tokens or
  signing material use exact current release SHAs, reviewed during maintenance.
- Do not add Dependabot or GitHub-hosted dependency-proposal jobs. Scheduled
  dependency upkeep belongs in Codex or on an owned machine, configured
  separately from repository CI.
- Installed apps update SDKs through explicit Settings actions at or above the
  bundled minimum version; agent CLIs follow the documented API requirements.
  Bundled signed or offline components reach users only through app delivery.
- Before each new release, refresh dependency selections to current stable
  releases, including Node Current, in development PRs. Validate and merge the
  updated lockfiles and generated resources before selecting the release commit.
  Release builds consume that accepted snapshot without resolving fresh versions.
