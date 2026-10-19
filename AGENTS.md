# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Never initiate or operate account login, device authorization, or authentication
  UI. Release authorization does not authorize authentication recovery. Use only
  existing credentials; never run `gh auth login`, `refresh`, `logout`, or `switch`.
  A sandboxed `gh` failure does not prove a missing or invalid credential. Retry
  the read-only `scripts/check-release-access.sh` through the approved execution
  permission path; if it still fails, stop and report the blocker to the user.
- Build and launch: `scripts/build_and_run.sh`.
- For UI work, follow [the style guide](docs/STYLE_GUIDE.md).
- Validate: `scripts/test-changes.sh`; use `--all` for changes spanning components.
  Development/main CI owns source validation. Release preparation never runs
  local test suites or reruns CI; follow the release skill to start the workflow.
  Tests must not consume provider services. Container lifecycle tests use
  `scripts/test-container.sh` when in scope and Docker is available.
- Release, installation, publication, and delivery require an explicit request.
  Always build and verify a private draft, then present its user-facing release
  description to Trey and wait for his explicit approval before publication.
  Version confirmation alone does not authorize publication.
  For releases, use `.agents/skills/cut-release-wovenmatter/SKILL.md`.

## Dependencies

Follow [the dependency policy](docs/DEPENDENCIES.md).

- Stay current. Declare ordinary npm dependencies with caret ranges whose floor
  is the tested release. Never leave a dependency on an old version or major
  line without a reason.
- An exact or narrowed selection needs a concrete security or core-function
  reason, documented beside it and in `docs/DEPENDENCIES.md`. It also needs
  a maintenance path (`scripts/update-runtime-dependencies.mjs` or an owner-run
  agent task) and a stated validation boundary.
- Lockfiles, `app/Package.resolved`, and the Node, CEF, and Sparkle records are
  required. Builds, tests, images, and launch use them (`npm ci`) and never
  resolve newer dependencies. Change them only through maintenance refresh, and
  regenerate dependent provenance in the same change. Never hand-edit
  `app/Package.resolved`; the maintenance pipeline generates one combined
  SwiftPM/Xcode graph. Normal builds consume it with resolution frozen.
- Keep checksums, signatures, updater keys, and provenance. Keep every copy of
  one selection in sync; the refresh script rejects drift.
- Read-only workflow helpers may track `@main`. Workflows with write tokens or
  signing material use exact current release SHAs, reviewed during maintenance.
- Do not add Dependabot or GitHub-hosted dependency-proposal jobs. Scheduled
  dependency upkeep belongs in Codex or on an owned machine, configured
  separately from repository CI.
- Installed apps update SDKs and agent CLIs only through explicit Settings
  actions, within the bundled compatibility range. Bundled signed or offline
  components reach users only through app delivery.
