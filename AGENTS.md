# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Never initiate or operate account login, device authorization, or authentication
  UI. Release authorization does not authorize authentication recovery. Use only
  existing credentials; never run `gh auth login`, `refresh`, `logout`, or `switch`.
  A sandboxed `gh` failure does not prove a missing or invalid credential. Retry
  the read-only `scripts/check-release-access.sh` through the approved execution
  permission path; if it still fails, stop and report the blocker to the user.
- [The architecture](docs/ARCHITECTURE.md) is the contract: the library, the
  background server and the thin UI, and the rules they keep. A change that
  breaks one of its rules is wrong even if it works.
- No version numbers inside the codebase: not on schemas, protocols, routes,
  tables, files, types, capabilities or features. Only the app has a version.
- Build and launch: `scripts/build_and_run.sh --instance NAME`. Each instance
  has its own bundle identifier, its own data folder and its own server. It
  never reads or changes the data of an installed app. `--port PORT` puts the
  instance's server on the tailnet; `--plan` prints the instance's profile
  without building.
- For UI work, follow [the style guide](docs/STYLE_GUIDE.md).
- Validate: `scripts/test-changes.sh`. It runs the static checks, the server
  package's tests (which cover `library/` and `protocol/`) and the Pi Durable
  and bots tests. `--ci` runs the same on Linux in pull request CI, which is one
  portable Linux check. `WOVEN_SWIFT_SCRATCH_PATH` gives a run its own Swift
  build folder. Tests must not consume provider services.
- Keep one-off audit reports, generated coverage inventories, and review evidence
  out of Git. Record results in PR descriptions or external build artifacts.
- Release, installation, publication, and delivery require an explicit request.
  Always build and verify a private draft, then present its user-facing release
  description to Trey and wait for his explicit approval before publication.
  Version confirmation alone does not authorize publication. Releases are built
  on this Mac with `scripts/cut-release.sh build` and `ship`; GitHub only signs
  and notarizes them. Release preparation never reruns CI.
  For releases, use `.agents/skills/cut-release-wovenmatter/SKILL.md`.
- `ios/` is not part of the build. Leave it alone.

## Dependencies

Follow [the dependency policy](docs/DEPENDENCIES.md).

- Stay current. Declare ordinary npm dependencies with minimum-only ranges
  (`>=version`) whose floor is the tested release; newer stable majors remain
  eligible. Never leave a dependency on an old version or major without a reason.
- An exact or narrowed selection needs a concrete security or core-function
  reason, documented beside it and in `docs/DEPENDENCIES.md`. It also needs
  a documented maintenance process and a stated validation boundary.
- Lockfiles, `app/Package.resolved`, `server/Package.resolved`, and the Node,
  CEF, Sparkle and Linux build records are required. Builds and tests consume
  the committed package graphs (`npm ci`, frozen Swift resolution) and runtime
  records. Change recorded selections through maintenance refresh and
  regenerate dependent provenance in the same change. Never hand-edit a
  `Package.resolved`; use package-manager tooling.
- Keep checksums, signatures, updater keys, and provenance. Keep every copy of
  one selection in sync and verify that the records agree before proposing updates.
- Read-only workflow helpers may track `@main`. Workflows with write tokens or
  signing material use exact current release SHAs, reviewed during maintenance.
- Do not add Dependabot or GitHub-hosted dependency-proposal jobs. Scheduled
  dependency upkeep belongs in Codex or on an owned machine, configured
  separately from repository CI.
- Bundled signed or offline components reach users only through app delivery.
- When cutting a release, first run `scripts/release-check.py` on this Mac, never
  on GitHub. Update anything outdated in one development PR and report known
  vulnerabilities, as the release skill describes. Release builds consume the
  lockfiles and runtime records committed on the release commit without
  resolving fresh versions.
