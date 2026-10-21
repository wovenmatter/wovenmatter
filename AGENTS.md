# Repository guidance

- Use the repository-configured GitHub SSH identity; never use the GitHub connector.
- Never initiate or operate account login, device authorization, or authentication
  UI. Release authorization does not authorize authentication recovery. Use only
  existing credentials; never run `gh auth login`, `refresh`, `logout`, or `switch`.
  A sandboxed `gh` failure does not prove a missing or invalid credential. Retry
  the read-only `scripts/check-release-access.sh` through the approved execution
  permission path; if it still fails, stop and report the blocker to the user.
- Build and launch: `scripts/build_and_run.sh`.
- Dev builds use independent named instances. When asked for a live client, use
  `scripts/build_and_run.sh --mode live`; for a snapshot, use `--mode snapshot`.
  If unspecified, choose live for UI, harness, tool, and instance-owned scheduling
  changes; choose snapshot for library-host, persistence/schema, protocol, or
  intentionally isolated tests. State the choice briefly and proceed without
  asking the user to choose. `--plan` prints the resolved profile without building
  or reading production data; `--mode auto` provides a conservative file-based
  fallback. Explicit user choice always wins. See [development builds](docs/DEVELOPMENT_BUILDS.md).
- Never point a Dev executable at the production SQLite file, copy another
  client's credentials, force-kill a running instance, or silently substitute a
  snapshot when live connection fails. Use `--instance NAME` for another instance
  of one worktree or a fresh snapshot; existing snapshots retain their edits.
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
